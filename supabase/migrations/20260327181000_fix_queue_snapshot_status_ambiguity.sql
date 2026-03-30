-- Fix get_raid_queue_snapshot after expanding its RETURNS TABLE shape.
-- The OUT parameter named status makes unqualified status references ambiguous
-- inside PL/pgSQL, so the queue-participant access check must use a table alias.

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
    SELECT 1 FROM public.raid_queues rq
    WHERE rq.raid_id = p_raid_id
      AND rq.user_id = v_uid
      AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.raids r
    WHERE r.id = p_raid_id AND r.host_user_id = v_uid
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