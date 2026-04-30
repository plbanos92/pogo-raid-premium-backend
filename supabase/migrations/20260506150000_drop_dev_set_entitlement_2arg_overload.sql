-- ─────────────────────────────────────────────────────────────────────────────
-- Drop the legacy 2-arg dev_set_entitlement(text, boolean) overload.
--
-- Why: Phase 2 (20260506110000) added a 4-arg form
--   dev_set_entitlement(p_plan text, p_active boolean,
--                       p_period_end timestamptz DEFAULT NULL,
--                       p_cancel_at_period_end boolean DEFAULT false)
-- and the migration comment claimed "Postgres dispatches by arg count" —
-- that is only true for positional calls. PostgREST sends **named**
-- arguments, and with named args both overloads are equally valid when
-- only p_plan and p_active are supplied, producing:
--   "Could not choose the best candidate function between:
--      public.dev_set_entitlement(p_plan => text, p_active => boolean),
--      public.dev_set_entitlement(p_plan => text, p_active => boolean,
--                                 p_period_end => timestamp with time zone,
--                                 p_cancel_at_period_end => boolean)"
-- which broke the "buy dark mode" / VIP toggle flows in dev/test mode.
--
-- The 4-arg form fully subsumes the 2-arg one (period_end defaults NULL,
-- cancel_at_period_end defaults false), so dropping the legacy overload
-- is safe.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.dev_set_entitlement(text, boolean);

NOTIFY pgrst, 'reload schema';
