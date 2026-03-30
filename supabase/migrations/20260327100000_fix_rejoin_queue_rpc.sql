-- Fix: allow users to rejoin a raid queue after leaving (left/done status).
--
-- Root cause: join_raid_queue returned the existing row for any (raid_id, user_id)
-- match — including 'left' and 'done' entries — which meant the user appeared to
-- "join" but their status stayed 'left', invisible to listMyQueues.
-- Because of the unique index ux_raid_queues_raid_user, we UPDATE the terminal
-- row back to 'queued' instead of inserting a new one.

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

  -- A terminal (left/done) row exists — UPDATE it back to queued.
  -- We cannot INSERT because of the unique index on (raid_id, user_id).
  UPDATE public.raid_queues
  SET
    status     = 'queued',
    position   = v_current_size + 1,
    note       = COALESCE(p_note, note),
    joined_at  = now(),
    invited_at = NULL,
    updated_at = now()
  WHERE raid_id = p_raid_id
    AND user_id  = v_uid
  RETURNING * INTO v_result;

  IF FOUND THEN
    RETURN v_result;
  END IF;

  -- No existing row at all — fresh INSERT.
  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position)
  VALUES (p_raid_id, v_uid, p_note, 'queued', v_current_size + 1)
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;
