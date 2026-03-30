-- Prevent hosts from joining their own active raid as queue participants.
--
-- This enforces the rule server-side for both direct raid joins and boss queue
-- joins, so the UI cannot be bypassed by calling the RPCs directly.

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

  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  SELECT *
  INTO v_existing
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND user_id  = v_uid
    AND status NOT IN ('left', 'done');

  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT capacity, host_user_id
  INTO v_capacity, v_host_user_id
  FROM public.raids
  WHERE id = p_raid_id
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found or inactive';
  END IF;

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

  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position)
  VALUES (p_raid_id, v_uid, p_note, 'queued', v_current_size + 1)
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

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

  SELECT r.id INTO v_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = p_boss_id
    AND r.is_active = true
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