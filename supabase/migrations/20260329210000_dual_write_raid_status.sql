-- 20260329210000_dual_write_raid_status.sql
-- Phase 2: Dual-write raids.status alongside is_active in all lifecycle RPCs.
-- Every state-changing RPC now writes raids.status atomically with the
-- existing is_active / queue-status transitions.
--
-- Sync rules applied:
--   open      → no write needed (column default; also set when last confirmed user leaves)
--   lobby     → SET status = 'lobby'   on first user_confirm_invite (idempotent)
--   raiding   → SET status = 'raiding' on start_raid
--   completed → SET is_active = false, status = 'completed'  on finish_raiding / host_finish_raiding
--   cancelled → SET is_active = false, status = 'cancelled'  on check_host_inactivity
--
-- is_active remains the authoritative read column (Phase 3 will migrate reads).
-- No function signatures, return types, or non-status logic were changed.

-- ============================================================
-- 1. start_raid: fold status = 'raiding' into the existing raids UPDATE
-- ============================================================
CREATE OR REPLACE FUNCTION public.start_raid(p_raid_id uuid)
RETURNS public.raids
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_raid public.raids%ROWTYPE;
  v_confirmed int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_raid FROM public.raids
  WHERE id = p_raid_id AND host_user_id = v_uid AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or already inactive'
      USING ERRCODE = '42501';
  END IF;

  -- Must have at least one confirmed participant
  SELECT COUNT(*) INTO v_confirmed
  FROM public.raid_queues
  WHERE raid_id = p_raid_id AND status = 'confirmed';
  IF v_confirmed = 0 THEN
    RAISE EXCEPTION 'No confirmed participants to start with';
  END IF;

  -- Transition confirmed → raiding
  UPDATE public.raid_queues SET status = 'raiding'
  WHERE raid_id = p_raid_id AND status = 'confirmed';

  -- Cancel users who hadn't confirmed yet
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited');

  -- Raid stays is_active = true (raiding in progress)
  -- Reset host_finished_at in case of any stale data
  -- Phase 2: also set status = 'raiding'
  UPDATE public.raids
  SET host_finished_at = NULL,
      status = 'raiding'::raid_status_enum
  WHERE id = p_raid_id
  RETURNING * INTO v_raid;

  RETURN v_raid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_raid(uuid) TO authenticated;


-- ============================================================
-- 2. user_confirm_invite: set status = 'lobby' on first confirmation (idempotent)
--    Source: latest definition from 20260327183000_allow_queue_confirmation_without_host_invite.sql
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
  SET status = 'confirmed'
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

GRANT EXECUTE ON FUNCTION public.user_confirm_invite(uuid) TO authenticated;


-- ============================================================
-- 3. leave_queue_and_promote: revert raid to 'open' when last confirmed user leaves
-- ============================================================
CREATE OR REPLACE FUNCTION public.leave_queue_and_promote(
  p_queue_id uuid,
  p_note text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.raid_queues%ROWTYPE;
  v_left public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_row
  FROM public.raid_queues
  WHERE id = p_queue_id
    AND user_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue entry not found'
      USING ERRCODE = '42501';
  END IF;

  IF v_row.status = 'left' THEN
    RETURN v_row;
  END IF;

  IF v_row.status = 'done' THEN
    RAISE EXCEPTION 'Cannot leave a completed queue entry'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.raid_queues
  SET status = 'left',
      note = COALESCE(p_note, note),
      updated_at = now()
  WHERE id = p_queue_id
  RETURNING * INTO v_left;

  IF v_row.status IN ('invited', 'confirmed') THEN
    PERFORM public.promote_next_queued_user(v_left.raid_id);
  END IF;

  -- Phase 2: if the departing entry was 'confirmed' and no confirmed entries
  -- remain for this raid, revert raid status from 'lobby' back to 'open'.
  IF v_row.status = 'confirmed' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.raid_queues
      WHERE raid_id = v_left.raid_id AND status = 'confirmed'
    ) THEN
      UPDATE public.raids
      SET status = 'open'::raid_status_enum
      WHERE id = v_left.raid_id
        AND status = 'lobby'::raid_status_enum;
    END IF;
  END IF;

  RETURN v_left;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_queue_and_promote(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_queue_and_promote(uuid, text) TO authenticated;


-- ============================================================
-- 4. finish_raiding: set status = 'completed' alongside is_active = false
-- ============================================================
CREATE OR REPLACE FUNCTION public.finish_raiding(p_queue_id uuid)
RETURNS public.raid_queues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.raid_queues%ROWTYPE;
  v_updated public.raid_queues%ROWTYPE;
  v_still_raiding int;
  v_host_done boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.raid_queues
  WHERE id = p_queue_id AND user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue entry not found' USING ERRCODE = '42501';
  END IF;
  IF v_row.status <> 'raiding' THEN
    RAISE EXCEPTION 'Can only finish a raiding entry, current: %', v_row.status;
  END IF;

  UPDATE public.raid_queues SET status = 'done'
  WHERE id = p_queue_id RETURNING * INTO v_updated;

  -- Check if raid is fully complete
  SELECT COUNT(*) INTO v_still_raiding
  FROM public.raid_queues
  WHERE raid_id = v_row.raid_id AND status = 'raiding';

  SELECT (host_finished_at IS NOT NULL) INTO v_host_done
  FROM public.raids WHERE id = v_row.raid_id;

  -- Phase 2: set status = 'completed' atomically with is_active = false
  IF v_still_raiding = 0 AND v_host_done THEN
    UPDATE public.raids
    SET is_active = false,
        status = 'completed'::raid_status_enum
    WHERE id = v_row.raid_id;
  END IF;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.finish_raiding(uuid) TO authenticated;


-- ============================================================
-- 5. host_finish_raiding: set status = 'completed' alongside is_active = false
-- ============================================================
CREATE OR REPLACE FUNCTION public.host_finish_raiding(p_raid_id uuid)
RETURNS public.raids
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_raid public.raids%ROWTYPE;
  v_still_raiding int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_raid FROM public.raids
  WHERE id = p_raid_id AND host_user_id = v_uid AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or already inactive'
      USING ERRCODE = '42501';
  END IF;
  IF v_raid.host_finished_at IS NOT NULL THEN
    RAISE EXCEPTION 'You already finished raiding';
  END IF;

  -- Check that raid is in raiding phase
  IF NOT EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status IN ('raiding', 'done')
  ) THEN
    RAISE EXCEPTION 'Raid has not been started yet';
  END IF;

  UPDATE public.raids SET host_finished_at = now()
  WHERE id = p_raid_id RETURNING * INTO v_raid;

  -- Check if all joiners are also done
  SELECT COUNT(*) INTO v_still_raiding
  FROM public.raid_queues
  WHERE raid_id = p_raid_id AND status = 'raiding';

  -- Phase 2: set status = 'completed' atomically with is_active = false
  IF v_still_raiding = 0 THEN
    UPDATE public.raids
    SET is_active = false,
        status = 'completed'::raid_status_enum
    WHERE id = p_raid_id;
    SELECT * INTO v_raid FROM public.raids WHERE id = p_raid_id;
  END IF;

  RETURN v_raid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.host_finish_raiding(uuid) TO authenticated;


-- ============================================================
-- 6. check_host_inactivity: set status = 'cancelled' alongside is_active = false
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_host_inactivity(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid public.raids%ROWTYPE;
  v_lobby_size int;
  v_new_raid_id uuid;
  v_entry record;
BEGIN
  SELECT * INTO v_raid FROM public.raids WHERE id = p_raid_id AND is_active = true;
  IF NOT FOUND THEN RETURN false; END IF;

  -- Check: has host been inactive for 100s?
  IF v_raid.last_host_action_at >= now() - interval '100 seconds' THEN
    RETURN false;
  END IF;

  -- Check: is lobby full?
  SELECT COUNT(*) INTO v_lobby_size
  FROM public.raid_queues WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');
  IF v_lobby_size < v_raid.capacity THEN RETURN false; END IF;

  -- Phase 2: set status = 'cancelled' atomically with is_active = false
  UPDATE public.raids
  SET is_active = false,
      status = 'cancelled'::raid_status_enum
  WHERE id = p_raid_id;

  -- Find best alternative raid for same boss
  SELECT r.id INTO v_new_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = v_raid.raid_boss_id
    AND r.is_active = true
    AND r.id <> p_raid_id
    AND (SELECT COUNT(*) FROM public.raid_queues q
         WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) < r.capacity
  ORDER BY (SELECT COUNT(*) FROM public.raid_queues q
            WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) DESC
  LIMIT 1;

  -- Re-queue each affected user (with priority boost)
  FOR v_entry IN
    SELECT user_id, note FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed')
  LOOP
    IF v_new_raid_id IS NOT NULL THEN
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (v_new_raid_id, v_entry.user_id, 'queued', true,
              'Re-queued (host inactivity) — priority restored')
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END IF;
  END LOOP;

  -- Cancel original entries
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');

  -- Recompute positions in new raid if users were added
  IF v_new_raid_id IS NOT NULL THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_host_inactivity(uuid) TO authenticated;
