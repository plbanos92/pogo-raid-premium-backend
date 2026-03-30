-- Migration F — get_raid_queue_snapshot RPC
-- Returns a lightweight ordered queue list for the visual queue line (Phase 4).
-- VIP entries first, then FIFO. Caller must be in the queue or be the host.
-- Only display_name (truncated) is exposed — no user_id, no email, no friend code.

CREATE OR REPLACE FUNCTION public.get_raid_queue_snapshot(p_raid_id uuid)
RETURNS TABLE (
  "position"      int,
  is_vip          boolean,
  status          text,
  display_name    text,
  is_me           boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Caller must either be in the queue or be the host of the raid
  IF NOT EXISTS (
    SELECT 1 FROM public.raid_queues
    WHERE raid_id = p_raid_id
      AND user_id = v_uid
      AND status IN ('queued', 'invited', 'confirmed')
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
      LEFT(p.display_name, 12),
      'Player'
    )                                       AS display_name,
    (q.user_id = v_uid)                     AS is_me
  FROM public.raid_queues q
  LEFT JOIN public.user_profiles p ON p.auth_id = q.user_id
  WHERE q.raid_id = p_raid_id
    AND q.status IN ('queued', 'invited', 'confirmed')
  ORDER BY q.is_vip DESC, q.joined_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_raid_queue_snapshot(uuid) TO authenticated;
