-- Phase 4: Egg Lobby Hosting — Hatch RPCs
-- Adds two RPCs for transitioning egg lobbies to open:
--   1. hatch_raid(uuid)          — host-only manual hatch
--   2. auto_hatch_expired_eggs() — timer-driven maintenance, opens all eggs
--                                  within the 2-minute pre-hatch window

-- ============================================================
-- 1. hatch_raid(p_raid_id uuid)
--    Host-callable. Only the raid host may call it.
--    Transitions a single egg lobby to 'open'.
--    Sets status_changed_at = now() so get_queue_sync_state's
--    raidsVersion bumps on the next poll.
-- ============================================================

CREATE OR REPLACE FUNCTION public.hatch_raid(p_raid_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_host_user_id uuid;
  v_status       raid_status_enum;
BEGIN
  SELECT host_user_id, status
    INTO v_host_user_id, v_status
    FROM public.raids
    WHERE id = p_raid_id;

  IF v_host_user_id IS NULL THEN
    RAISE EXCEPTION 'raid_not_found';
  END IF;

  IF v_host_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not_host';
  END IF;

  IF v_status <> 'egg' THEN
    RAISE EXCEPTION 'raid_not_egg: current status is %', v_status;
  END IF;

  UPDATE public.raids
    SET status            = 'open',
        status_changed_at = now(),
        updated_at        = now()
    WHERE id = p_raid_id;
END;
$$;

REVOKE ALL ON FUNCTION public.hatch_raid(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatch_raid(uuid) TO authenticated;

-- ============================================================
-- 2. auto_hatch_expired_eggs()
--    Timer-driven maintenance RPC called from the frontend
--    maintenance poll. Opens all egg lobbies where
--    hatch_time <= now() + interval '2 minutes'.
--    Returns the count of raids hatched.
--    FOR UPDATE SKIP LOCKED prevents concurrent double-processing.
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_hatch_expired_eggs()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_hatched int := 0;
  v_raid    RECORD;
BEGIN
  FOR v_raid IN
    SELECT id
    FROM public.raids
    WHERE status    = 'egg'
      AND hatch_time IS NOT NULL
      AND hatch_time <= now() + interval '2 minutes'
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.raids
      SET status            = 'open',
          status_changed_at = now(),
          updated_at        = now()
      WHERE id = v_raid.id;
    v_hatched := v_hatched + 1;
  END LOOP;

  RETURN v_hatched;
END;
$$;

REVOKE ALL ON FUNCTION public.auto_hatch_expired_eggs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_hatch_expired_eggs() TO authenticated;
