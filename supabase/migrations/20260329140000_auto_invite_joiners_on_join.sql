-- Auto-fill available raid slots by joining users as invited instead of queued.
-- This preserves the existing confirmation flow while making open host lobbies
-- appear populated immediately in the host lobby UI.

CREATE OR REPLACE FUNCTION public.join_raid_queue(
  p_raid_id uuid,
  p_note text DEFAULT NULL
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
  v_current_size int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize queue enrollment per raid to avoid duplicate positions under concurrency.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  -- Only treat an existing row as a blocker if it is still active (not left/done).
  SELECT *
  INTO v_existing
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND user_id  = v_uid
    AND status NOT IN ('left', 'done');

  IF FOUND THEN
    RETURN v_existing;  -- Idempotent: already in an active queue slot.
  END IF;

  SELECT capacity
  INTO v_capacity
  FROM public.raids
  WHERE id = p_raid_id
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found or inactive';
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

  -- An active slot exists, so the new joiner is auto-filled into the lobby.
  UPDATE public.raid_queues
  SET
    status     = 'invited',
    position   = v_current_size + 1,
    note       = COALESCE(p_note, note),
    joined_at  = now(),
    invited_at = now(),
    updated_at = now()
  WHERE raid_id = p_raid_id
    AND user_id  = v_uid
  RETURNING * INTO v_result;

  IF FOUND THEN
    RETURN v_result;
  END IF;

  -- No existing row at all — fresh insert directly into the lobby.
  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position, invited_at)
  VALUES (p_raid_id, v_uid, p_note, 'invited', v_current_size + 1, now())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;