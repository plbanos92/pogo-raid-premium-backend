-- 20260329220000_read_side_status_predicates.sql
-- Phase 3: Migrate read-side predicates from is_active to explicit status.
--
-- Phases 1 and 2 added raids.status (enum: open/lobby/raiding/completed/cancelled)
-- and dual-wrote it alongside is_active in every state-changing RPC. Both columns
-- are now synchronized. This phase switches all read/filter paths in RPCs and
-- views to use status predicates; the dual-write compatibility bridge (is_active)
-- is left completely untouched.
--
-- Predicate mapping applied throughout:
--   joinable (can accept new queue entries): status IN ('open', 'lobby')
--   active (non-terminal, host dashboard):   status NOT IN ('completed', 'cancelled')
--   terminal:                                status IN ('completed', 'cancelled')
--
-- Functions rewritten (CREATE OR REPLACE — atomic, preserves existing GRANTs):
--   1. join_raid_queue   — capacity-check guard + idempotency fix for terminal rows
--   2. join_boss_queue   — eligibility filter on raids
--   3. boss_queue_stats  — both is_active occurrences in the view
--   4. get_queue_sync_state — v_hosted_raids_version sub-query only

-- ============================================================
-- 1. join_raid_queue
--    Change 1a: capacity-check guard  AND is_active = true
--                                  →  AND status IN ('open', 'lobby')
--    Change 1b: idempotency fix — terminal rows ('left', 'cancelled', 'done')
--               are deleted so the user can re-enroll;
--               only genuinely active rows ('queued', 'invited', 'confirmed',
--               'raiding') short-circuit and return the existing entry.
--
-- Source:   20260329170000_restore_host_self_join_guard.sql
-- Invariants carried forward (must never be dropped):
--   (1) Host self-join guard     (introduced 20260329103000)
--   (2) Auto-invite-on-join — status = 'invited' on every fresh insert
--                              (introduced 20260329140000)
-- ============================================================
CREATE OR REPLACE FUNCTION public.join_raid_queue(
  p_raid_id uuid,
  p_note    text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_existing     public.raid_queues%ROWTYPE;
  v_result       public.raid_queues%ROWTYPE;
  v_capacity     int;
  v_host_user_id uuid;
  v_current_size int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize queue enrollment per raid to avoid duplicate positions under concurrency.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  -- Check for any existing row for this user in this raid (no status filter — we
  -- need to see terminal rows so we can delete them cleanly).
  SELECT *
  INTO v_existing
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND user_id  = v_uid;

  IF FOUND THEN
    IF v_existing.status IN ('queued', 'invited', 'confirmed', 'raiding') THEN
      RETURN v_existing;  -- Idempotent: already in an active queue slot.
    END IF;
    -- Terminal status ('left', 'cancelled', 'done'): remove the stale row so
    -- fresh enrollment can proceed through the INSERT path below.
    DELETE FROM public.raid_queues WHERE id = v_existing.id;
  END IF;

  -- Phase 3: gate on explicit status instead of is_active.
  SELECT capacity, host_user_id
  INTO v_capacity, v_host_user_id
  FROM public.raids
  WHERE id = p_raid_id
    AND status IN ('open', 'lobby')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found or inactive';
  END IF;

  -- Invariant (1): hosts cannot join their own lobby as a player.
  IF v_host_user_id = v_uid THEN
    RAISE EXCEPTION 'Hosts cannot join their own lobby as a player'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*)
  INTO v_current_size
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND status IN ('queued', 'invited', 'confirmed');

  IF v_current_size >= v_capacity THEN
    RAISE EXCEPTION 'Raid queue is full'
      USING ERRCODE = '23514';
  END IF;

  -- Invariant (2): auto-fill new joiner directly into 'invited' status.
  -- The stale row (if any) was deleted above, so we always INSERT here.
  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position, invited_at)
  VALUES (p_raid_id, v_uid, p_note, 'invited', v_current_size + 1, now())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.join_raid_queue(uuid, text) TO authenticated;


-- ============================================================
-- 2. join_boss_queue
--    Change: r.is_active = true  →  r.status IN ('open', 'lobby')
--    Only raids open for new queue entries are eligible.
--    Users cannot land in a raid that is already raiding, completed, or cancelled.
--
-- Source: 20260329103000_prevent_host_self_join.sql (latest definition)
-- ============================================================
CREATE OR REPLACE FUNCTION public.join_boss_queue(
  p_boss_id uuid,
  p_note    text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_raid_id uuid;
  v_result  public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Phase 3: status IN ('open', 'lobby') replaces is_active = true.
  SELECT r.id INTO v_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = p_boss_id
    AND r.status IN ('open', 'lobby')
    AND r.host_user_id <> v_uid
    AND (
      SELECT COUNT(*)
      FROM public.raid_queues q
      WHERE q.raid_id = r.id
        AND q.status IN ('queued', 'invited', 'confirmed')
    ) < r.capacity
  ORDER BY (
    SELECT COUNT(*)
    FROM public.raid_queues q
    WHERE q.raid_id = r.id
      AND q.status IN ('queued', 'invited', 'confirmed')
  ) DESC
  LIMIT 1;

  IF v_raid_id IS NULL THEN
    RAISE EXCEPTION 'No eligible active raid available for this boss'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_result FROM public.join_raid_queue(v_raid_id, p_note);
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.join_boss_queue(uuid, text) TO authenticated;


-- ============================================================
-- 3. boss_queue_stats view
--    Change: every  r.is_active = true
--              →    r.status NOT IN ('completed', 'cancelled')
--    active_hosts counts open/lobby/raiding raids (non-terminal).
--    queue_length counts queued/invited entries in non-terminal raids.
--
-- Source: 20260326140000_add_boss_scheduling_and_admin.sql (latest definition)
-- ============================================================
CREATE OR REPLACE VIEW public.boss_queue_stats AS
SELECT
  rb.id,
  rb.name,
  rb.tier,
  rb.cp,
  rb.image_url,
  rb.types,
  rb.pokemon_id,
  COALESCE((
    SELECT COUNT(*)::int
    FROM public.raids r
    WHERE r.raid_boss_id = rb.id
      AND r.status NOT IN ('completed', 'cancelled')
  ), 0) AS active_hosts,
  COALESCE((
    SELECT COUNT(*)::int
    FROM public.raid_queues q
    JOIN public.raids r ON r.id = q.raid_id
    WHERE r.raid_boss_id = rb.id
      AND r.status NOT IN ('completed', 'cancelled')
      AND q.status IN ('queued', 'invited')
  ), 0) AS queue_length
FROM public.raid_bosses rb
WHERE rb.is_visible = true
  AND (rb.available_from IS NULL OR rb.available_from <= now())
  AND (rb.available_until IS NULL OR rb.available_until > now());

GRANT SELECT ON public.boss_queue_stats TO anon, authenticated;


-- ============================================================
-- 4. get_queue_sync_state
--    Change: v_hosted_raids_version sub-query only.
--              AND r.is_active = true
--            → AND r.status NOT IN ('completed', 'cancelled')
--    v_my_queues_version and v_managing_lobby_version do NOT filter on
--    is_active and are reproduced here without any modification.
--
-- Source: 20260328090000_add_queue_sync_state_rpc.sql
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_queue_sync_state(
  p_managing_raid_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_my_queues_version timestamptz;
  v_hosted_raids_version timestamptz;
  v_managing_lobby_version timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Unchanged: my queue entries across all raids I have joined.
  SELECT GREATEST(
    COALESCE(MAX(q.updated_at), '-infinity'::timestamptz),
    COALESCE(MAX(r.updated_at), '-infinity'::timestamptz)
  )
  INTO v_my_queues_version
  FROM public.raid_queues q
  LEFT JOIN public.raids r ON r.id = q.raid_id
  WHERE q.user_id = v_uid
    AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done');

  -- Phase 3: switch from is_active = true to status NOT IN ('completed', 'cancelled').
  -- Tracks version changes on all non-terminal hosted raids and their queue entries.
  SELECT GREATEST(
    COALESCE(MAX(r.updated_at), '-infinity'::timestamptz),
    COALESCE(MAX(q.updated_at), '-infinity'::timestamptz)
  )
  INTO v_hosted_raids_version
  FROM public.raids r
  LEFT JOIN public.raid_queues q
    ON q.raid_id = r.id
   AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  WHERE r.host_user_id = v_uid
    AND r.status NOT IN ('completed', 'cancelled');

  -- Unchanged: specific lobby being actively managed by this host.
  IF p_managing_raid_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.raids r
       WHERE r.id = p_managing_raid_id
         AND r.host_user_id = v_uid
     ) THEN
    SELECT GREATEST(
      COALESCE(MAX(r.updated_at), '-infinity'::timestamptz),
      COALESCE(MAX(q.updated_at), '-infinity'::timestamptz)
    )
    INTO v_managing_lobby_version
    FROM public.raids r
    LEFT JOIN public.raid_queues q
      ON q.raid_id = r.id
     AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
    WHERE r.id = p_managing_raid_id;
  ELSE
    v_managing_lobby_version := NULL;
  END IF;

  RETURN jsonb_build_object(
    'myQueuesVersion', CASE WHEN v_my_queues_version = '-infinity'::timestamptz THEN NULL ELSE v_my_queues_version END,
    'hostedRaidsVersion', CASE WHEN v_hosted_raids_version = '-infinity'::timestamptz THEN NULL ELSE v_hosted_raids_version END,
    'managingLobbyVersion', CASE WHEN v_managing_lobby_version = '-infinity'::timestamptz THEN NULL ELSE v_managing_lobby_version END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_queue_sync_state(uuid) TO authenticated;
