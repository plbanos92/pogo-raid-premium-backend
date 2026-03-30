-- Expose limited host profile details to raid participants without exposing friend codes.

DROP FUNCTION IF EXISTS public.get_raid_host_profile(uuid);

CREATE OR REPLACE FUNCTION public.get_raid_host_profile(p_raid_id uuid)
RETURNS TABLE (
  auth_id uuid,
  display_name text,
  in_game_name text,
  trainer_level smallint,
  team text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.raid_queues rq
    WHERE rq.raid_id = p_raid_id
      AND rq.user_id = v_uid
      AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ) AND NOT EXISTS (
    SELECT 1
    FROM public.raids r
    WHERE r.id = p_raid_id
      AND r.host_user_id = v_uid
      AND r.is_active = true
  ) THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    up.auth_id,
    up.display_name,
    up.in_game_name,
    up.trainer_level,
    up.team
  FROM public.raids r
  LEFT JOIN public.user_profiles up ON up.auth_id = r.host_user_id
  WHERE r.id = p_raid_id
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_raid_host_profile(uuid) TO authenticated;