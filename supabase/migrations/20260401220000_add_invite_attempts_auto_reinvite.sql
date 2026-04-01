-- Phase 1: Auto-reinvite on joiner idle expire
-- Adds invite_attempts counter to raid_queues, rewrites expire_stale_invites
-- to auto-reinvite up to 3 times, and resets the counter in confirm/invite/promote RPCs.

-- ============================================================
-- A. Schema change: invite_attempts column
-- ============================================================

ALTER TABLE public.raid_queues ADD COLUMN IF NOT EXISTS invite_attempts int NOT NULL DEFAULT 0;
ALTER TABLE public.raid_queues ADD CONSTRAINT chk_invite_attempts_non_negative CHECK (invite_attempts >= 0);

-- ============================================================
-- B. Rewrite expire_stale_invites(p_raid_id uuid)
-- ============================================================

CREATE OR REPLACE FUNCTION public.expire_stale_invites(p_raid_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid_status text;
  v_capacity int;
  v_confirmed int;
  v_reinvited int := 0;
  v_reverted int := 0;
BEGIN
  -- Early exit: no expired entries
  IF NOT EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id
      AND status = 'invited'
      AND invited_at < now() - interval '60 seconds'
  ) THEN
    RETURN 0;
  END IF;

  -- Read raid status and capacity
  SELECT r.status, r.capacity
    INTO v_raid_status, v_capacity
    FROM public.raids r
   WHERE r.id = p_raid_id;

  -- Count confirmed entries
  SELECT COUNT(*) INTO v_confirmed
    FROM public.raid_queues
   WHERE raid_id = p_raid_id AND status = 'confirmed';

  -- UPDATE 1 — Auto-reinvite path:
  -- Only if raid is eligible (open/lobby) and has room
  IF v_raid_status IN ('open', 'lobby') AND v_confirmed < v_capacity THEN
    UPDATE public.raid_queues
    SET status = 'invited',
        invited_at = now(),
        invite_attempts = invite_attempts + 1,
        updated_at = now()
    WHERE raid_id = p_raid_id
      AND status = 'invited'
      AND invited_at < now() - interval '60 seconds'
      AND invite_attempts < 3;
    GET DIAGNOSTICS v_reinvited = ROW_COUNT;
  END IF;

  -- UPDATE 2 — Revert path: all remaining expired entries
  UPDATE public.raid_queues
  SET status = 'queued',
      invited_at = NULL,
      updated_at = now()
  WHERE raid_id = p_raid_id
    AND status = 'invited'
    AND invited_at < now() - interval '60 seconds';
  GET DIAGNOSTICS v_reverted = ROW_COUNT;

  -- Position recompute (trg_recompute_positions does NOT fire on invited → queued)
  IF v_reverted > 0 THEN
    UPDATE public.raid_queues SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE raid_queues.id = sub.id;
  END IF;

  RETURN v_reinvited + v_reverted;
END;
$$;

-- ============================================================
-- C. Revise user_confirm_invite — add invite_attempts = 0
-- ============================================================

CREATE OR REPLACE FUNCTION public.user_confirm_invite(p_queue_id uuid)
RETURNS public.raid_queues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.raid_queues%ROWTYPE;
  v_updated public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.raid_queues
  WHERE id = p_queue_id AND user_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue entry not found' USING ERRCODE = '42501';
  END IF;

  IF v_row.status = 'confirmed' THEN
    RETURN v_row;
  END IF;

  IF v_row.status NOT IN ('queued', 'invited') THEN
    RAISE EXCEPTION 'Can only confirm a queued or invited entry, current: %', v_row.status;
  END IF;

  UPDATE public.raid_queues
  SET status = 'confirmed',
      invite_attempts = 0
  WHERE id = p_queue_id
  RETURNING * INTO v_updated;

  INSERT INTO public.raid_confirmations (raid_queue_id, confirmed_by)
  SELECT p_queue_id, v_uid
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.raid_confirmations rc
    WHERE rc.raid_queue_id = p_queue_id
      AND rc.confirmed_by = v_uid
  );

  -- Phase 2: transition raid to 'lobby' on first confirmation.
  -- Idempotent: WHERE clause is a no-op if status is already 'lobby' or later.
  UPDATE public.raids
  SET status = 'lobby'::raid_status_enum
  WHERE id = v_updated.raid_id
    AND status = 'open'::raid_status_enum;

  RETURN v_updated;
END;
$$;

-- ============================================================
-- D. Revise host_invite_next_in_queue — add invite_attempts = 0
-- ============================================================

CREATE OR REPLACE FUNCTION public.host_invite_next_in_queue(
  p_raid_id uuid
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_invited public.raid_queues%ROWTYPE;
  v_expired int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.raids r
    WHERE r.id = p_raid_id
      AND r.host_user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Only the raid host can invite users for this raid'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize host invitation decisions per raid.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  -- Expire stale invites first (60s timeout)
  SELECT public.expire_stale_invites(p_raid_id) INTO v_expired;

  -- One-invite-at-a-time guard: reject if someone is already invited
  IF EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status = 'invited'
  ) THEN
    RAISE EXCEPTION 'Another user is already invited — wait for their response'
      USING ERRCODE = 'P0001';
  END IF;

  WITH candidate AS (
    SELECT q.id
    FROM public.raid_queues q
    WHERE q.raid_id = p_raid_id
      AND q.status = 'queued'
    ORDER BY q.is_vip DESC, q.joined_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.raid_queues q
  SET status = 'invited',
      invite_attempts = 0
  FROM candidate c
  WHERE q.id = c.id
  RETURNING q.* INTO v_invited;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No queued users available for invitation';
  END IF;

  RETURN v_invited;
END;
$$;

-- ============================================================
-- E. Revise promote_next_queued_user — add invite_attempts = 0
-- ============================================================

CREATE OR REPLACE FUNCTION public.promote_next_queued_user(p_raid_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  WITH candidate AS (
    SELECT q.id
    FROM public.raid_queues q
    WHERE q.raid_id = p_raid_id
      AND q.status = 'queued'
    ORDER BY q.is_vip DESC, q.joined_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.raid_queues q
  SET status = 'invited',
      invited_at = now(),
      updated_at = now(),
      invite_attempts = 0
  FROM candidate c
  WHERE q.id = c.id;
END;
$$;
