-- Update get_queue_sync_state to include raidsVersion using status_changed_at.
-- IMPORTANT: uses status_changed_at, NOT updated_at, to avoid false-positive
-- refreshData() calls caused by touch_host_activity heartbeats (every ~10 s).
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
  v_my_queues_version      timestamptz;
  v_hosted_raids_version   timestamptz;
  v_managing_lobby_version timestamptz;
  v_raids_version          timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- User's own queue rows (unchanged)
  SELECT GREATEST(
    COALESCE(MAX(q.updated_at), '-infinity'::timestamptz),
    COALESCE(MAX(r.updated_at), '-infinity'::timestamptz)
  )
  INTO v_my_queues_version
  FROM public.raid_queues q
  LEFT JOIN public.raids r ON r.id = q.raid_id
  WHERE q.user_id = v_uid
    AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done');

  -- User's hosted raids (unchanged)
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
    AND r.status NOT IN ('completed', 'cancelled');

  -- Managing lobby cursor (unchanged)
  IF p_managing_raid_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.raids r
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

  -- NEW: global raids status-change version. Uses status_changed_at (not updated_at).
  -- Bumps only on status transitions (open->lobby, lobby->raiding, raiding->completed, etc.).
  -- Heartbeats from touch_host_activity do NOT bump this.
  -- Design note: when a raid closes, its status_changed_at is bumped to now() by the
  -- conditional trigger, but it is then excluded from this WHERE clause. This means
  -- raidsVersion may DECREASE if the only changed raid was the closing one and
  -- remaining open raids have older status_changed_at values. This is intentional:
  -- syncCursorChanged uses !==, not >, so any change (up or down) triggers refreshData().
  SELECT COALESCE(MAX(status_changed_at), '-infinity'::timestamptz)
  INTO v_raids_version
  FROM public.raids
  WHERE status NOT IN ('completed', 'cancelled');

  RETURN jsonb_build_object(
    'myQueuesVersion',      CASE WHEN v_my_queues_version      = '-infinity'::timestamptz THEN NULL ELSE v_my_queues_version      END,
    'hostedRaidsVersion',   CASE WHEN v_hosted_raids_version   = '-infinity'::timestamptz THEN NULL ELSE v_hosted_raids_version   END,
    'managingLobbyVersion', CASE WHEN v_managing_lobby_version = '-infinity'::timestamptz THEN NULL ELSE v_managing_lobby_version END,
    'raidsVersion',         CASE WHEN v_raids_version          = '-infinity'::timestamptz THEN NULL ELSE v_raids_version          END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_queue_sync_state(uuid) TO authenticated;
