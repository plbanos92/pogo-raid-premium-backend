-- Restore the host self-join guard that was dropped when auto_invite_joiners_on_join
-- (20260329140000) re-defined join_raid_queue without carrying forward the check
-- introduced in 20260329103000_prevent_host_self_join.sql.
--
-- This merges both changes: auto-invite-on-join AND the host guard.

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

  SELECT capacity, host_user_id
  INTO v_capacity, v_host_user_id
  FROM public.raids
  WHERE id = p_raid_id
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found or inactive';
  END IF;

  -- Hosts cannot join their own lobby as a player.
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

  -- An active slot is available, so auto-fill the new joiner directly into the lobby.
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

  -- No existing row — fresh insert directly into the lobby.
  INSERT INTO public.raid_queues (raid_id, user_id, note, status, position, invited_at)
  VALUES (p_raid_id, v_uid, p_note, 'invited', v_current_size + 1, now())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;
