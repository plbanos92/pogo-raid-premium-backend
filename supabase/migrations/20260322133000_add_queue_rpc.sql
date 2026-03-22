-- Phase 2: Transaction-safe RPC functions for queue and host operations.

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
  v_uid uuid := auth.uid();
  v_existing public.raid_queues%ROWTYPE;
  v_created public.raid_queues%ROWTYPE;
  v_capacity int;
  v_current_size int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize queue enrollment per raid to avoid duplicate positions under concurrency.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  SELECT *
  INTO v_existing
  FROM public.raid_queues
  WHERE raid_id = p_raid_id
    AND user_id = v_uid;

  IF FOUND THEN
    RETURN v_existing;
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

  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position)
  VALUES (p_raid_id, v_uid, p_note, 'queued', v_current_size + 1)
  RETURNING * INTO v_created;

  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.host_invite_next_in_queue(
  p_raid_id uuid
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_invited public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.raids r
    WHERE r.id = p_raid_id
      AND r.host_user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Only the raid host can invite users for this raid'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize host invitation decisions per raid.
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  WITH candidate AS (
    SELECT q.id
    FROM public.raid_queues q
    WHERE q.raid_id = p_raid_id
      AND q.status = 'queued'
    ORDER BY q.is_vip DESC, q.joined_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.raid_queues q
  SET status = 'invited'
  FROM candidate c
  WHERE q.id = c.id
  RETURNING q.* INTO v_invited;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No queued users available for invitation';
  END IF;

  RETURN v_invited;
END;
$$;

CREATE OR REPLACE FUNCTION public.host_update_queue_status(
  p_queue_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_updated public.raid_queues%ROWTYPE;
  v_allowed text[] := ARRAY['queued', 'invited', 'confirmed', 'declined', 'cancelled', 'left'];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT (p_status = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'Invalid queue status: %', p_status;
  END IF;

  UPDATE public.raid_queues q
  SET status = p_status,
      note = COALESCE(p_note, q.note)
  FROM public.raids r
  WHERE q.id = p_queue_id
    AND r.id = q.raid_id
    AND r.host_user_id = v_uid
  RETURNING q.* INTO v_updated;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue row not found or caller is not the raid host'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.join_raid_queue(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.host_invite_next_in_queue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.host_update_queue_status(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.join_raid_queue(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.host_invite_next_in_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.host_update_queue_status(uuid, text, text) TO authenticated;
