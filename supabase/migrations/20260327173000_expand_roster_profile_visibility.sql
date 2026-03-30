-- Expand raid roster payloads for queue participants and hosts.
-- Hosts can see joiner team/level alongside friend-code QR data.
-- Joiners can see teammate identity/team/level without exposing friend codes.

DROP FUNCTION IF EXISTS public.list_raid_queue(uuid);

CREATE OR REPLACE FUNCTION public.list_raid_queue(p_raid_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
  "position" int,
  is_vip boolean,
  note text,
  joined_at timestamptz,
  invited_at timestamptz,
  display_name text,
  in_game_name text,
  friend_code text,
  trainer_level smallint,
  team text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.raids
    WHERE raids.id = p_raid_id AND host_user_id = v_uid AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or inactive'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    rq.id,
    rq.user_id,
    rq.status,
    rq.position,
    rq.is_vip,
    rq.note,
    rq.joined_at,
    rq.invited_at,
    up.display_name,
    up.in_game_name,
    up.friend_code,
    up.trainer_level,
    up.team
  FROM public.raid_queues rq
  LEFT JOIN public.user_profiles up ON up.auth_id = rq.user_id
  WHERE rq.raid_id = p_raid_id
    AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ORDER BY rq.is_vip DESC, rq.joined_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_raid_queue(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.get_raid_queue_snapshot(uuid);

CREATE OR REPLACE FUNCTION public.get_raid_queue_snapshot(p_raid_id uuid)
RETURNS TABLE (
  "position" int,
  is_vip boolean,
  status text,
  display_name text,
  in_game_name text,
  trainer_level smallint,
  team text,
  is_me boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id
      AND user_id = v_uid
      AND status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.raids
    WHERE id = p_raid_id AND host_user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY q.is_vip DESC, q.joined_at ASC
    )::int                                  AS "position",
    q.is_vip,
    q.status::text,
    COALESCE(
      LEFT(up.display_name, 12),
      'Player'
    )                                       AS display_name,
    up.in_game_name,
    up.trainer_level,
    up.team,
    (q.user_id = v_uid)                     AS is_me
  FROM public.raid_queues q
  LEFT JOIN public.user_profiles up ON up.auth_id = q.user_id
  WHERE q.raid_id = p_raid_id
    AND q.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ORDER BY q.is_vip DESC, q.joined_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_raid_queue_snapshot(uuid) TO authenticated;