-- ─────────────────────────────────────────────────────────────────────────────
-- Fix ambiguous column reference in get_my_entitlements().
--
-- Why: Phase 2 (20260506110000) declared RETURNS TABLE(is_vip boolean, ...)
-- which exposes those names as PL/pgSQL OUT variables inside the body.
-- The inline CTE used `WHERE is_vip = true` unqualified, which Postgres
-- could not resolve between the OUT variable and active_subs.is_vip:
--
--   ERROR: 42702: column reference "is_vip" is ambiguous
--   DETAIL: It could refer to either a PL/pgSQL variable or a table column.
--
-- Effect: every call to get_my_entitlements() raised at runtime, so the
-- frontend's getMyEntitlements() promise rejected (caught + swallowed),
-- leaving state.isVip / state.hasDarkUnlock perpetually false. The "Buy
-- Dark Mode" button never flipped to "Remove Dark Mode" / "Included with
-- VIP" and the Account view never showed the theme switcher.
--
-- Fix: rename CTE-internal columns to avoid collision with OUT params,
-- and qualify all references explicitly. Body logic is unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_my_entitlements();
CREATE OR REPLACE FUNCTION public.get_my_entitlements()
RETURNS TABLE (
  is_vip                   boolean,
  has_dark_unlock          boolean,
  vip_plan                 text,
  vip_status               text,
  vip_current_period_end   timestamptz,
  vip_cancel_at_period_end boolean,
  dark_unlock_acquired_at  timestamptz,
  payments_test_mode       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY
      SELECT false, false,
             NULL::text, NULL::text, NULL::timestamptz, false,
             NULL::timestamptz,
             COALESCE((SELECT ac.payments_test_mode FROM public.app_config ac WHERE ac.id = 1), true);
    RETURN;
  END IF;

  RETURN QUERY
  WITH active_subs AS (
    SELECT s.plan         AS sub_plan,
           s.status       AS sub_status,
           s.is_vip       AS sub_is_vip,
           s.ends_at      AS sub_ends_at,
           s.current_period_end   AS sub_current_period_end,
           s.cancel_at_period_end AS sub_cancel_at_period_end,
           s.starts_at    AS sub_starts_at
      FROM public.subscriptions s
     WHERE s.user_id = v_uid
       AND s.status = 'active'
       AND (s.ends_at IS NULL OR s.ends_at > now())
  ),
  vip_row AS (
    SELECT a.sub_plan, a.sub_status, a.sub_current_period_end,
           a.sub_cancel_at_period_end, a.sub_ends_at
      FROM active_subs a
     WHERE a.sub_is_vip = true OR a.sub_plan = 'vip_monthly'
     ORDER BY COALESCE(a.sub_current_period_end, a.sub_ends_at) DESC NULLS LAST
     LIMIT 1
  ),
  dark_row AS (
    SELECT a.sub_starts_at
      FROM active_subs a
     WHERE a.sub_plan = 'dark_unlock'
     ORDER BY a.sub_starts_at DESC NULLS LAST
     LIMIT 1
  )
  SELECT
    EXISTS (SELECT 1 FROM active_subs a WHERE a.sub_is_vip = true OR a.sub_plan = 'vip_monthly') AS is_vip,
    EXISTS (SELECT 1 FROM active_subs a WHERE a.sub_plan = 'dark_unlock')                       AS has_dark_unlock,
    (SELECT v.sub_plan                                          FROM vip_row v)                 AS vip_plan,
    (SELECT v.sub_status                                        FROM vip_row v)                 AS vip_status,
    (SELECT COALESCE(v.sub_current_period_end, v.sub_ends_at)   FROM vip_row v)                 AS vip_current_period_end,
    (SELECT COALESCE(v.sub_cancel_at_period_end, false)         FROM vip_row v)                 AS vip_cancel_at_period_end,
    (SELECT d.sub_starts_at                                     FROM dark_row d)                AS dark_unlock_acquired_at,
    COALESCE((SELECT ac.payments_test_mode FROM public.app_config ac WHERE ac.id = 1), true)    AS payments_test_mode;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_entitlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_entitlements() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
