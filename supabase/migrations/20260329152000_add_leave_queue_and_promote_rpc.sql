-- Explicit leave RPC: mark the caller's queue row left and auto-promote the next queued user.

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

  RETURN v_left;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_queue_and_promote(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_queue_and_promote(uuid, text) TO authenticated;