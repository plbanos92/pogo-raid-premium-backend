-- Entitlements Phase 1: secure boundary for VIP / Dark Mode / Free tier.
--
-- Goals:
--   1. Stop letting clients self-grant `is_vip` via direct INSERT on subscriptions.
--   2. Centralize entitlement reads via get_my_entitlements() so frontend and
--      backend agree on expiry semantics (is_vip AND status='active' AND
--      (ends_at IS NULL OR ends_at > now())).
--   3. Introduce a `plan` column so future tiers (dark_unlock, vip_plus, ...)
--      slot in without schema churn.
--   4. Provide a dev-mode toggle RPC (dev_set_entitlement) that mimics what a
--      payments webhook will eventually do, gated by app_config.payments_test_mode.
--   5. Keep existing raid_queues.is_vip trigger and queue ordering untouched —
--      they already read subscriptions.is_vip and stay authoritative for queue
--      priority. Only the WRITE path changes.
--
-- After this migration:
--   - Direct INSERT/UPDATE/DELETE on subscriptions from `authenticated` is denied.
--   - Clients call rpc.dev_set_entitlement(plan, active) which runs as SECURITY
--     DEFINER and enforces auth.uid() + payments_test_mode.
--   - Clients call rpc.get_my_entitlements() to read current state.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. app_config: dev-mode flag + dark unlock display fields
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.app_config
  ADD COLUMN IF NOT EXISTS payments_test_mode boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS dark_unlock_price text NOT NULL DEFAULT '$5',
  ADD COLUMN IF NOT EXISTS dark_unlock_price_period text NOT NULL DEFAULT ' one-time',
  ADD COLUMN IF NOT EXISTS dark_unlock_features jsonb NOT NULL DEFAULT '[
    {"icon":"moon",   "text":"Full dark theme everywhere"},
    {"icon":"zap",    "text":"Smooth neon pills & glow accents"},
    {"icon":"shield", "text":"Fancy gradient QR frame"},
    {"icon":"check",  "text":"One-time payment, yours forever"}
  ]'::jsonb;

COMMENT ON COLUMN public.app_config.payments_test_mode IS
  'When true, dev_set_entitlement() is callable by any authenticated user for
   their own row (used to fake purchases in dev/staging). Flip to false in a
   production migration once a real payments webhook is wired up — only
   apply_provider_event() and admins can grant entitlements after that.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. subscriptions: add `plan` column and tighten check constraint
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS plan text;

-- Backfill existing rows: VIP rows become 'vip_monthly'.
UPDATE public.subscriptions
   SET plan = 'vip_monthly'
 WHERE plan IS NULL
   AND is_vip = true;

ALTER TABLE public.subscriptions
  DROP CONSTRAINT IF EXISTS subscriptions_plan_chk;

ALTER TABLE public.subscriptions
  ADD CONSTRAINT subscriptions_plan_chk
  CHECK (plan IS NULL OR plan IN ('vip_monthly', 'dark_unlock'));

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_plan_status
  ON public.subscriptions (user_id, plan, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Lock down direct writes on subscriptions
-- ─────────────────────────────────────────────────────────────────────────────
-- Replace the FOR ALL policy with SELECT-only. All entitlement writes must go
-- through SECURITY DEFINER RPCs (dev_set_entitlement today, apply_provider_event
-- tomorrow). This closes the self-grant exploit where any authenticated user
-- could POST { user_id, is_vip:true, status:'active' } via PostgREST.

DROP POLICY IF EXISTS "Users manage own subscriptions" ON public.subscriptions;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'Users select own subscriptions' AND tablename = 'subscriptions'
  ) THEN
    EXECUTE $q$
      CREATE POLICY "Users select own subscriptions" ON public.subscriptions
        FOR SELECT
        TO authenticated
        USING (user_id = auth.uid());
    $q$;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Revoke direct table-level write privileges from public roles. RPCs run as
-- the function owner (SECURITY DEFINER) and are unaffected.
REVOKE INSERT, UPDATE, DELETE ON public.subscriptions FROM anon, authenticated;
GRANT  SELECT                  ON public.subscriptions TO   anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_my_entitlements() — single source of truth for the frontend
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_my_entitlements()
RETURNS TABLE (
  is_vip                  boolean,
  has_dark_unlock         boolean,
  vip_plan                text,
  vip_status              text,
  vip_current_period_end  timestamptz,
  payments_test_mode      boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    -- Anonymous: everyone is free tier. Still return a row so the client has
    -- a stable shape and can read payments_test_mode.
    RETURN QUERY
      SELECT false, false, NULL::text, NULL::text, NULL::timestamptz,
             COALESCE((SELECT ac.payments_test_mode FROM public.app_config ac WHERE ac.id = 1), true);
    RETURN;
  END IF;

  RETURN QUERY
  WITH active_subs AS (
    SELECT s.plan, s.status, s.is_vip, s.ends_at
      FROM public.subscriptions s
     WHERE s.user_id = v_uid
       AND s.status = 'active'
       AND (s.ends_at IS NULL OR s.ends_at > now())
  ),
  vip_row AS (
    SELECT plan, status, ends_at
      FROM active_subs
     WHERE is_vip = true OR plan = 'vip_monthly'
     ORDER BY ends_at DESC NULLS LAST
     LIMIT 1
  )
  SELECT
    EXISTS (SELECT 1 FROM active_subs WHERE is_vip = true OR plan = 'vip_monthly')                AS is_vip,
    EXISTS (SELECT 1 FROM active_subs WHERE plan = 'dark_unlock')                                 AS has_dark_unlock,
    (SELECT plan    FROM vip_row)                                                                 AS vip_plan,
    (SELECT status  FROM vip_row)                                                                 AS vip_status,
    (SELECT ends_at FROM vip_row)                                                                 AS vip_current_period_end,
    COALESCE((SELECT ac.payments_test_mode FROM public.app_config ac WHERE ac.id = 1), true)      AS payments_test_mode;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_entitlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_entitlements() TO anon, authenticated;

COMMENT ON FUNCTION public.get_my_entitlements() IS
  'Returns the calling user''s computed entitlements. Single source of truth for
   the frontend — replaces direct REST queries on subscriptions. Always returns
   exactly one row.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. dev_set_entitlement() — fake purchase / cancellation for dev mode
-- ─────────────────────────────────────────────────────────────────────────────
-- Gated by app_config.payments_test_mode. Once that flag flips to false in a
-- future production migration, this RPC raises EXCEPTION and only an
-- apply_provider_event() RPC (Phase 3) can mutate entitlements.

CREATE OR REPLACE FUNCTION public.dev_set_entitlement(
  p_plan   text,
  p_active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_test_mode boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'dev_set_entitlement: not authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_plan NOT IN ('vip_monthly', 'dark_unlock') THEN
    RAISE EXCEPTION 'dev_set_entitlement: unknown plan %', p_plan USING ERRCODE = '22023';
  END IF;

  SELECT payments_test_mode INTO v_test_mode
    FROM public.app_config WHERE id = 1;

  IF NOT COALESCE(v_test_mode, false) THEN
    RAISE EXCEPTION 'dev_set_entitlement: disabled in production (payments_test_mode=false)'
      USING ERRCODE = '42501';
  END IF;

  IF p_active THEN
    -- Activate: upsert an active row for (user_id, plan).
    -- We don't use ON CONFLICT because there's no unique key on (user_id, plan)
    -- and adding one would risk colliding with future provider-driven rows.
    -- Instead, cancel any existing active row for this plan, then insert fresh.
    UPDATE public.subscriptions
       SET status     = 'cancelled',
           ends_at    = now()
     WHERE user_id = v_uid
       AND plan    = p_plan
       AND status  = 'active';

    INSERT INTO public.subscriptions
      (user_id, provider, status, is_vip, plan, starts_at, ends_at)
    VALUES
      (v_uid, 'dev', 'active',
       (p_plan = 'vip_monthly'),  -- only vip_monthly flips the legacy is_vip flag
       p_plan, now(), NULL);
  ELSE
    -- Deactivate: cancel all active rows for this plan.
    UPDATE public.subscriptions
       SET status  = 'cancelled',
           ends_at = now()
     WHERE user_id = v_uid
       AND plan    = p_plan
       AND status  = 'active';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.dev_set_entitlement(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dev_set_entitlement(text, boolean) TO authenticated;

COMMENT ON FUNCTION public.dev_set_entitlement(text, boolean) IS
  'Dev-only: simulate a purchase/cancellation for the calling user. Disabled
   when app_config.payments_test_mode is false. Replace with apply_provider_event()
   when wiring real payments.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Reload PostgREST schema cache
-- ─────────────────────────────────────────────────────────────────────────────

NOTIFY pgrst, 'reload schema';
