-- Migration: fix ambiguous column reference in admin_list_users
-- PL/pgSQL RETURNS TABLE creates implicit output variables with the same names
-- as table columns (is_admin, is_vip, auth_id, etc.), causing PostgreSQL to
-- raise "column reference is ambiguous". The #variable_conflict use_column
-- directive tells PL/pgSQL to prefer column references over output variables.

CREATE OR REPLACE FUNCTION public.admin_list_users(
  p_page      int DEFAULT 0,
  p_page_size int DEFAULT 20
)
RETURNS TABLE (
  auth_id         uuid,
  email           text,
  display_name    text,
  in_game_name    text,
  friend_code     text,
  is_admin        boolean,
  is_vip          boolean,
  vip_since       timestamptz,
  vip_until       timestamptz,
  joined_at       timestamptz,
  last_sign_in_at timestamptz,
  total_count     bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  -- Only admins may call this function.
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE auth_id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    up.auth_id,
    au.email::text,
    up.display_name,
    up.in_game_name,
    up.friend_code,
    COALESCE(up.is_admin, false)    AS is_admin,
    COALESCE(s.is_vip, false)       AS is_vip,
    s.starts_at                     AS vip_since,
    s.ends_at                       AS vip_until,
    up.created_at                   AS joined_at,
    au.last_sign_in_at,
    COUNT(*) OVER()                 AS total_count
  FROM public.user_profiles up
  JOIN auth.users au ON au.id = up.auth_id
  LEFT JOIN LATERAL (
    SELECT is_vip, starts_at, ends_at
    FROM public.subscriptions
    WHERE user_id = up.auth_id
      AND is_vip = true
      AND status = 'active'
    ORDER BY starts_at DESC
    LIMIT 1
  ) s ON true
  ORDER BY up.created_at DESC
  LIMIT  GREATEST(1, LEAST(p_page_size, 100))
  OFFSET GREATEST(0, p_page) * GREATEST(1, LEAST(p_page_size, 100));
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_users(int, int) TO authenticated;
