-- Allow auto-filled lobby entries to confirm themselves without a host invite step.
-- The host no longer needs to manually promote queued players to invited before
-- they can add the host and mark themselves ready.

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

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.user_confirm_invite(uuid) TO authenticated;