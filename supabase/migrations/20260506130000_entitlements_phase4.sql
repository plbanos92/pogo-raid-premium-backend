-- Entitlements Phase 4: checkout URL configuration.
--
-- Adds checkout URLs to app_config. The frontend reads payments_test_mode:
--   - true  (current dev mode): buttons call dev_set_entitlement().
--   - false (production):       buttons redirect to the checkout URL below.
--
-- The production cutover is a single follow-up migration that:
--   1. UPDATE public.app_config SET vip_checkout_url = '<stripe url>',
--                                   dark_unlock_checkout_url = '<stripe url>',
--                                   payments_test_mode = false WHERE id = 1;
--   2. (No code change required — the frontend already branches on the flag.)

ALTER TABLE public.app_config
  ADD COLUMN IF NOT EXISTS vip_checkout_url         text,
  ADD COLUMN IF NOT EXISTS dark_unlock_checkout_url text;

COMMENT ON COLUMN public.app_config.vip_checkout_url IS
  'Hosted checkout URL for the VIP subscription. NULL means no live checkout
   configured — the frontend falls back to the dev toggle when payments_test_mode
   is true, or shows a "coming soon" message when false and URL is NULL.';

COMMENT ON COLUMN public.app_config.dark_unlock_checkout_url IS
  'Hosted checkout URL for the one-time Dark Mode unlock. Same fallback rules
   as vip_checkout_url.';

NOTIFY pgrst, 'reload schema';
