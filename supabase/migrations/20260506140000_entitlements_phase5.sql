-- Entitlements Phase 5: in-app cancellation.
--
-- Adds request_cancel_subscription(p_plan, p_cancel) — lets the user toggle
-- cancel_at_period_end on their own active subscription without leaving the
-- app. Mirrors what Stripe's Billing Portal does:
--   - p_cancel=true  → flip cancel_at_period_end=true; row stays active until
--                       current_period_end; no refund.
--   - p_cancel=false → undo (re-enable auto-renew).
--
-- This RPC ONLY mutates cancel_at_period_end. It does NOT change status. A
-- subsequent provider webhook (subscription.cancelled / subscription.expired)
-- is the only thing that actually ends access. In dev mode there's no provider,
-- so VIP stays active until ends_at — which is fine because the dev RPC
-- already set ends_at=NULL.
--
-- The Worker is responsible for calling the real provider's API (e.g.
-- stripe.subscriptions.update({ cancel_at_period_end })) when this RPC fires.
-- That's done in a follow-up: the RPC writes the intent to the DB, the worker
-- observes the change (or the frontend calls a worker route after the RPC) and
-- forwards it to the provider. For now this RPC just updates the DB row — the
-- provider sync is a separate concern that doesn't block dev/staging UX.

CREATE OR REPLACE FUNCTION public.request_cancel_subscription(
  p_plan   text,
  p_cancel boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_updated   int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'request_cancel_subscription: not authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_plan NOT IN ('vip_monthly') THEN
    -- dark_unlock is one-time and has no recurring cycle to cancel.
    RAISE EXCEPTION 'request_cancel_subscription: plan % is not cancellable', p_plan
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.subscriptions
     SET cancel_at_period_end = COALESCE(p_cancel, true)
   WHERE user_id = v_uid
     AND plan    = p_plan
     AND status  = 'active'
     AND (ends_at IS NULL OR ends_at > now());

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    RAISE EXCEPTION 'request_cancel_subscription: no active subscription for plan %', p_plan
      USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'plan', p_plan,
    'cancel_at_period_end', COALESCE(p_cancel, true),
    'updated', v_updated
  );
END;
$$;

REVOKE ALL ON FUNCTION public.request_cancel_subscription(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_cancel_subscription(text, boolean) TO authenticated;

COMMENT ON FUNCTION public.request_cancel_subscription(text, boolean) IS
  'User-facing: toggle cancel_at_period_end on the calling user''s active
   subscription. Status remains active until the provider sends a
   subscription.cancelled / subscription.expired webhook (handled by
   apply_provider_event). Re-callable with p_cancel=false to uncancel.';

NOTIFY pgrst, 'reload schema';
