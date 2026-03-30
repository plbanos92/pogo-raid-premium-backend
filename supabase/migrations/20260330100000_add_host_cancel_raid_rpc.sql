-- 20260330100000_add_host_cancel_raid_rpc.sql
-- Host-initiated raid cancellation RPC.
-- Follows the check_host_inactivity requeue pattern (see 20260325160000).
--
-- Key differences from check_host_inactivity:
--   - No inactivity or lobby-fullness check — host cancels unconditionally
--   - Handles open, lobby, and raiding statuses
--   - Explicit caller identity check (security guard)
--   - Entries with status 'raiding' are NOT requeued or cancelled (raid already started for them)
--   - SELECT ... FOR UPDATE prevents race with concurrent start_raid
--
-- Trigger notes:
--   - trg_validate_raid_status (BEFORE UPDATE): allows open→cancelled, lobby→cancelled, raiding→cancelled
--   - trg_log_raid_status (AFTER UPDATE): fires automatically; actor_user_id = caller's JWT sub
--   - trg_refresh_host_action_at fires before validate (alphabetical), updates last_host_action_at — harmless here

CREATE OR REPLACE FUNCTION public.host_cancel_raid(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid;
  v_raid        public.raids%ROWTYPE;
  v_new_raid_id uuid;
  v_entry       record;
BEGIN
  -- 1. Resolve caller from JWT
  v_caller_id := NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  -- 2. Lock row to serialize with concurrent start_raid / check_host_inactivity calls.
  --    If start_raid holds the lock first and transitions to 'raiding', this function
  --    will proceed with raiding→cancelled (allowed by validate_raid_status trigger).
  --    If this lock is acquired first, start_raid will see is_active=false and return false gracefully.
  SELECT * INTO v_raid
  FROM public.raids
  WHERE id = p_raid_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN false; END IF;

  -- 3. Security guard: only the host may cancel
  IF v_raid.host_user_id <> v_caller_id THEN
    RAISE EXCEPTION 'Not authorized to cancel this raid' USING ERRCODE = '42501';
  END IF;

  -- 4. Idempotency: no-op if already terminal
  IF v_raid.status IN ('cancelled', 'completed') THEN RETURN false; END IF;

  -- 5. Defensive guard on is_active
  IF NOT v_raid.is_active THEN RETURN false; END IF;

  -- 6. Cancel the raid atomically.
  --    validate_raid_status trigger enforces: open→cancelled, lobby→cancelled, raiding→cancelled (all OK).
  --    log_raid_status_change trigger writes audit row automatically.
  UPDATE public.raids
  SET is_active = false,
      status    = 'cancelled'
  WHERE id = p_raid_id;

  -- 7. Find best alternative raid for same boss:
  --    most occupied but not yet full, active, different raid.
  --    NULL if no valid alternative exists — silently skips requeue below.
  SELECT r.id INTO v_new_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = v_raid.raid_boss_id
    AND r.is_active    = true
    AND r.id          <> p_raid_id
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

  -- 8. Requeue each pre-raid joiner with priority boost.
  --    'raiding' entries are deliberately excluded — those players are mid-raid.
  --    ON CONFLICT DO NOTHING handles the case where a user is already in the target raid.
  --    If v_new_raid_id IS NULL, the INSERT is skipped — entries are still cancelled in step 9.
  FOR v_entry IN
    SELECT user_id, note
    FROM public.raid_queues
    WHERE raid_id = p_raid_id
      AND status IN ('queued', 'invited', 'confirmed')
  LOOP
    IF v_new_raid_id IS NOT NULL THEN
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (
        v_new_raid_id,
        v_entry.user_id,
        'queued',
        true,
        'Re-queued (host cancelled raid) — priority restored'
      )
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END IF;
  END LOOP;

  -- 9. Cancel original pre-raid entries. 'raiding' entries are intentionally untouched.
  UPDATE public.raid_queues
  SET status = 'cancelled'
  WHERE raid_id = p_raid_id
    AND status IN ('queued', 'invited', 'confirmed');

  -- 10. Recompute positions in target raid (VIP first, then join order)
  IF v_new_raid_id IS NOT NULL THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id
               ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id
        AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.host_cancel_raid(uuid) TO authenticated;
