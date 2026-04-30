-- Entitlements Phase 2: provider-aware columns + period end semantics.
--
-- Adds the columns a real payments provider (Stripe/RevenueCat/IAP) needs:
--   - current_period_end: when the active period rolls over.
--   - cancel_at_period_end: user cancelled but still has access until end.
--   - price_id, customer_id: provider product/customer identifiers.
--   - provider_event_id: webhook idempotency key.
--
-- Updates get_my_entitlements() to surface cancel_at_period_end so the UI can
-- show "Cancels on <date>" without inventing client-side state.
--
-- dev_set_entitlement() gains a p_period_end argument so dev-mode subscriptions
-- can carry a realistic period end. Existing callers (no arg) get NULL —
-- equivalent to the old behaviour.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New columns on subscriptions
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS current_period_end   timestamptz,
  ADD COLUMN IF NOT EXISTS cancel_at_period_end boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS price_id             text,
  ADD COLUMN IF NOT EXISTS customer_id          text,
  ADD COLUMN IF NOT EXISTS provider_event_id    text;

-- Idempotency: each provider webhook event applies at most once.
CREATE UNIQUE INDEX IF NOT EXISTS ux_subscriptions_provider_event_id
  ON public.subscriptions (provider_event_id)
  WHERE provider_event_id IS NOT NULL;

-- Faster lookup by customer (for webhook handlers resolving customer→user).
CREATE INDEX IF NOT EXISTS idx_subscriptions_customer_id
  ON public.subscriptions (customer_id)
  WHERE customer_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_my_entitlements(): expose cancel_at_period_end + dark unlock period
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
    SELECT s.plan, s.status, s.is_vip, s.ends_at, s.current_period_end,
           s.cancel_at_period_end, s.starts_at
      FROM public.subscriptions s
     WHERE s.user_id = v_uid
       AND s.status = 'active'
       AND (s.ends_at IS NULL OR s.ends_at > now())
  ),
  vip_row AS (
    SELECT plan, status, current_period_end, cancel_at_period_end, ends_at
      FROM active_subs
     WHERE is_vip = true OR plan = 'vip_monthly'
     ORDER BY COALESCE(current_period_end, ends_at) DESC NULLS LAST
     LIMIT 1
  ),
  dark_row AS (
    SELECT starts_at
      FROM active_subs
     WHERE plan = 'dark_unlock'
     ORDER BY starts_at DESC NULLS LAST
     LIMIT 1
  )
  SELECT
    EXISTS (SELECT 1 FROM active_subs WHERE is_vip = true OR plan = 'vip_monthly')         AS is_vip,
    EXISTS (SELECT 1 FROM active_subs WHERE plan = 'dark_unlock')                          AS has_dark_unlock,
    (SELECT plan                                  FROM vip_row)                            AS vip_plan,
    (SELECT status                                FROM vip_row)                            AS vip_status,
    (SELECT COALESCE(current_period_end, ends_at) FROM vip_row)                            AS vip_current_period_end,
    (SELECT COALESCE(cancel_at_period_end, false) FROM vip_row)                            AS vip_cancel_at_period_end,
    (SELECT starts_at                             FROM dark_row)                           AS dark_unlock_acquired_at,
    COALESCE((SELECT ac.payments_test_mode FROM public.app_config ac WHERE ac.id = 1), true) AS payments_test_mode;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_entitlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_entitlements() TO anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. dev_set_entitlement(): accept optional period end + cancel_at_period_end
-- ─────────────────────────────────────────────────────────────────────────────
-- The 2-arg form (Phase 1) keeps working — Postgres dispatches by arg count.
-- This 4-arg form is what the frontend will call once Phase 2 ships.

CREATE OR REPLACE FUNCTION public.dev_set_entitlement(
  p_plan                 text,
  p_active               boolean,
  p_period_end           timestamptz DEFAULT NULL,
  p_cancel_at_period_end boolean     DEFAULT false
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
    UPDATE public.subscriptions
       SET status     = 'cancelled',
           ends_at    = now()
     WHERE user_id = v_uid
       AND plan    = p_plan
       AND status  = 'active';

    INSERT INTO public.subscriptions
      (user_id, provider, status, is_vip, plan, starts_at, ends_at,
       current_period_end, cancel_at_period_end)
    VALUES
      (v_uid, 'dev', 'active',
       (p_plan = 'vip_monthly'),
       p_plan, now(), NULL,
       p_period_end,
       COALESCE(p_cancel_at_period_end, false));
  ELSE
    UPDATE public.subscriptions
       SET status  = 'cancelled',
           ends_at = now()
     WHERE user_id = v_uid
       AND plan    = p_plan
       AND status  = 'active';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.dev_set_entitlement(text, boolean, timestamptz, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dev_set_entitlement(text, boolean, timestamptz, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
