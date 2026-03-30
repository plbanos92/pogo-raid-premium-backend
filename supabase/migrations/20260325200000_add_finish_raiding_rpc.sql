-- Migration G: finish_raiding (joiner) + host_finish_raiding (host) RPCs + auto-close logic
-- Phase 2 — Host Lobby & Raid Lifecycle

-- Joiner finishes raiding (raiding → done)
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

  IF v_still_raiding = 0 AND v_host_done THEN
    UPDATE public.raids SET is_active = false WHERE id = v_row.raid_id;
  END IF;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.finish_raiding(uuid) TO authenticated;

-- Host finishes raiding
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

  IF v_still_raiding = 0 THEN
    UPDATE public.raids SET is_active = false WHERE id = p_raid_id;
    SELECT * INTO v_raid FROM public.raids WHERE id = p_raid_id;
  END IF;

  RETURN v_raid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.host_finish_raiding(uuid) TO authenticated;
