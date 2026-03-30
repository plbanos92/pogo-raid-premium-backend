-- Return lightweight user-scoped version stamps for queue/lobby polling.
-- This lets the frontend poll cheaply and only run the heavier refreshData()
-- flow when queue or lobby data actually changed.

CREATE OR REPLACE FUNCTION public.get_queue_sync_state(
  p_managing_raid_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_my_queues_version timestamptz;
  v_hosted_raids_version timestamptz;
  v_managing_lobby_version timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT GREATEST(
    COALESCE(MAX(q.updated_at), '-infinity'::timestamptz),
    COALESCE(MAX(r.updated_at), '-infinity'::timestamptz)
  )
  INTO v_my_queues_version
  FROM public.raid_queues q
  LEFT JOIN public.raids r ON r.id = q.raid_id
  WHERE q.user_id = v_uid
    AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done');

  SELECT GREATEST(
    COALESCE(MAX(r.updated_at), '-infinity'::timestamptz),
    COALESCE(MAX(q.updated_at), '-infinity'::timestamptz)
  )
  INTO v_hosted_raids_version
  FROM public.raids r
  LEFT JOIN public.raid_queues q
    ON q.raid_id = r.id
   AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  WHERE r.host_user_id = v_uid
    AND r.is_active = true;

  IF p_managing_raid_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.raids r
       WHERE r.id = p_managing_raid_id
         AND r.host_user_id = v_uid
     ) THEN
    SELECT GREATEST(
      COALESCE(MAX(r.updated_at), '-infinity'::timestamptz),
      COALESCE(MAX(q.updated_at), '-infinity'::timestamptz)
    )
    INTO v_managing_lobby_version
    FROM public.raids r
    LEFT JOIN public.raid_queues q
      ON q.raid_id = r.id
     AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
    WHERE r.id = p_managing_raid_id;
  ELSE
    v_managing_lobby_version := NULL;
  END IF;

  RETURN jsonb_build_object(
    'myQueuesVersion', CASE WHEN v_my_queues_version = '-infinity'::timestamptz THEN NULL ELSE v_my_queues_version END,
    'hostedRaidsVersion', CASE WHEN v_hosted_raids_version = '-infinity'::timestamptz THEN NULL ELSE v_hosted_raids_version END,
    'managingLobbyVersion', CASE WHEN v_managing_lobby_version = '-infinity'::timestamptz THEN NULL ELSE v_managing_lobby_version END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_queue_sync_state(uuid) TO authenticated;