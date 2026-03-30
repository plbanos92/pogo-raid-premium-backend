-- Migration B: expire_stale_invites RPC + update host_invite_next_in_queue
-- Phase 1 — Invite & Confirm Flow

-- RPC: expire invited entries older than 60 seconds back to queued (tail)
CREATE OR REPLACE FUNCTION public.expire_stale_invites(p_raid_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count int := 0;
BEGIN
  -- Reset invited entries older than 60 seconds back to queued.
  -- joined_at is reset to now() so they re-enter at the tail for FIFO ordering.
  -- is_vip is preserved (subscription-based), so VIP subscribers still sort ahead.
  WITH expired AS (
    UPDATE public.raid_queues
    SET status = 'queued', invited_at = NULL, joined_at = now()
    WHERE raid_id = p_raid_id
      AND status = 'invited'
      AND invited_at < now() - interval '60 seconds'
    RETURNING id
  )
  SELECT COUNT(*) INTO v_count FROM expired;

  -- Recompute positions if any were reset
  IF v_count > 0 THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_invites(uuid) TO authenticated;

-- Update host_invite_next_in_queue to:
-- 1) Call expire_stale_invites before picking the next candidate
-- 2) Reject if an invited entry already exists (one-invite-at-a-time guard)
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
  SET status = 'invited'
  FROM candidate c
  WHERE q.id = c.id
  RETURNING q.* INTO v_invited;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No queued users available for invitation';
  END IF;

  RETURN v_invited;
END;
$$;
