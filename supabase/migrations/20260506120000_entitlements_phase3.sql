-- Entitlements Phase 3: provider webhook ingestion.
--
-- Adds apply_provider_event(jsonb) — the only entitlement writer that survives
-- the production cutover. Called by the Cloudflare Worker at
-- /api/webhooks/<provider> AFTER the worker has verified the provider's
-- signature. The worker authenticates to Postgres with the service_role JWT,
-- so no end-user auth.uid() is involved.
--
-- The RPC is provider-agnostic: it accepts a normalized event shape that the
-- worker constructs from raw Stripe / RevenueCat / Apple / Google payloads.
-- This keeps the database independent of any single payment provider.
--
-- Idempotency: provider_event_id is UNIQUE (added in Phase 2). The RPC checks
-- for an existing row first and short-circuits — webhook retries are safe.
--
-- Expected payload (jsonb):
-- {
--   "event_id":               "<provider's unique event id>",     -- required
--   "event_type":             "subscription.activated"            -- required
--                             | "subscription.updated"
--                             | "subscription.cancelled"
--                             | "subscription.expired"
--                             | "purchase.one_time",
--   "user_id":                "<uuid of the auth.users row>",     -- required
--   "plan":                   "vip_monthly" | "dark_unlock",      -- required
--   "provider":               "stripe" | "revenuecat" | "apple" | "google",
--   "customer_id":            "<provider customer id>",
--   "price_id":               "<provider price/product id>",
--   "current_period_end":     "<iso8601>",
--   "cancel_at_period_end":   false,
--   "starts_at":              "<iso8601>",
--   "ends_at":                "<iso8601 or null>"
-- }

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. provider_events audit table — keeps a record of every event we processed
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.provider_events (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id      text NOT NULL UNIQUE,
  provider      text NOT NULL,
  event_type    text NOT NULL,
  user_id       uuid,
  plan          text,
  raw_payload   jsonb NOT NULL,
  processed_at  timestamptz NOT NULL DEFAULT now(),
  result        text NOT NULL DEFAULT 'applied'
);

CREATE INDEX IF NOT EXISTS idx_provider_events_user
  ON public.provider_events (user_id, processed_at DESC);

ALTER TABLE public.provider_events ENABLE ROW LEVEL SECURITY;

-- No client-facing policies. service_role bypasses RLS.
COMMENT ON TABLE public.provider_events IS
  'Audit log of every payments provider webhook the worker has applied.
   Written exclusively by apply_provider_event(). Service-role read only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. apply_provider_event(jsonb)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.apply_provider_event(p_event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id            text  := p_event ->> 'event_id';
  v_event_type          text  := p_event ->> 'event_type';
  v_user_id             uuid  := NULLIF(p_event ->> 'user_id', '')::uuid;
  v_plan                text  := p_event ->> 'plan';
  v_provider            text  := COALESCE(p_event ->> 'provider', 'unknown');
  v_customer_id         text  := p_event ->> 'customer_id';
  v_price_id            text  := p_event ->> 'price_id';
  v_current_period_end  timestamptz := NULLIF(p_event ->> 'current_period_end', '')::timestamptz;
  v_starts_at           timestamptz := COALESCE(NULLIF(p_event ->> 'starts_at', '')::timestamptz, now());
  v_ends_at             timestamptz := NULLIF(p_event ->> 'ends_at', '')::timestamptz;
  v_cancel_at_pe        boolean     := COALESCE((p_event ->> 'cancel_at_period_end')::boolean, false);
  v_existing            uuid;
  v_target_status       text;
BEGIN
  -- ── Validation ──
  IF v_event_id IS NULL OR length(v_event_id) = 0 THEN
    RAISE EXCEPTION 'apply_provider_event: missing event_id' USING ERRCODE = '22023';
  END IF;
  IF v_event_type IS NULL THEN
    RAISE EXCEPTION 'apply_provider_event: missing event_type' USING ERRCODE = '22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'apply_provider_event: missing user_id' USING ERRCODE = '22023';
  END IF;
  IF v_plan NOT IN ('vip_monthly', 'dark_unlock') THEN
    RAISE EXCEPTION 'apply_provider_event: unknown plan %', v_plan USING ERRCODE = '22023';
  END IF;

  -- ── Idempotency: skip if we've already processed this event ──
  SELECT id INTO v_existing FROM public.provider_events WHERE event_id = v_event_id;
  IF FOUND THEN
    RETURN jsonb_build_object('result', 'duplicate', 'event_id', v_event_id);
  END IF;

  -- ── Determine target status from event_type ──
  v_target_status := CASE v_event_type
    WHEN 'subscription.activated' THEN 'active'
    WHEN 'subscription.updated'   THEN 'active'
    WHEN 'subscription.cancelled' THEN 'cancelled'
    WHEN 'subscription.expired'   THEN 'expired'
    WHEN 'purchase.one_time'      THEN 'active'  -- dark_unlock lifetime entitlement
    ELSE NULL
  END;

  IF v_target_status IS NULL THEN
    RAISE EXCEPTION 'apply_provider_event: unknown event_type %', v_event_type USING ERRCODE = '22023';
  END IF;

  -- ── Apply ──
  IF v_target_status = 'active' THEN
    -- Cancel any existing active row for this (user, plan), then insert a
    -- fresh active row carrying provider state.
    UPDATE public.subscriptions
       SET status  = 'cancelled',
           ends_at = COALESCE(ends_at, now())
     WHERE user_id = v_user_id
       AND plan    = v_plan
       AND status  = 'active'
       AND (provider IS DISTINCT FROM v_provider OR provider_subscription_id IS DISTINCT FROM (p_event ->> 'provider_subscription_id'));

    INSERT INTO public.subscriptions
      (user_id, provider, provider_subscription_id, status, is_vip, plan,
       starts_at, ends_at, current_period_end, cancel_at_period_end,
       price_id, customer_id, provider_event_id)
    VALUES
      (v_user_id, v_provider, p_event ->> 'provider_subscription_id',
       'active', (v_plan = 'vip_monthly'), v_plan,
       v_starts_at, v_ends_at, v_current_period_end, v_cancel_at_pe,
       v_price_id, v_customer_id, v_event_id)
    ON CONFLICT (provider_event_id) DO NOTHING;
  ELSE
    -- Cancellation / expiry: update existing active rows.
    UPDATE public.subscriptions
       SET status               = v_target_status,
           ends_at              = COALESCE(v_ends_at, current_period_end, now()),
           cancel_at_period_end = v_cancel_at_pe,
           current_period_end   = COALESCE(v_current_period_end, current_period_end)
     WHERE user_id = v_user_id
       AND plan    = v_plan
       AND status  = 'active';
  END IF;

  -- ── Audit ──
  INSERT INTO public.provider_events
    (event_id, provider, event_type, user_id, plan, raw_payload, result)
  VALUES
    (v_event_id, v_provider, v_event_type, v_user_id, v_plan, p_event, 'applied');

  RETURN jsonb_build_object('result', 'applied', 'event_id', v_event_id);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_provider_event(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_provider_event(jsonb) TO service_role;

COMMENT ON FUNCTION public.apply_provider_event(jsonb) IS
  'Service-role only. Called by the Cloudflare Worker at /api/webhooks/<provider>
   AFTER signature verification. Idempotent on event_id.';

NOTIFY pgrst, 'reload schema';
