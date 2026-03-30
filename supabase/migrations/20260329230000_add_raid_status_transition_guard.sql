-- Phase 4: Add DB-Level Raid Status Transition Guard
--
-- Enforces valid status transitions for public.raids at the database level.
-- A BEFORE UPDATE trigger blocks illegal status changes regardless of call path.
--
-- Allowed transitions:
--   open      → lobby, cancelled
--   lobby     → open, raiding, cancelled
--   raiding   → completed, cancelled
--   completed → (terminal)
--   cancelled → (terminal)
--   Same-value updates always allowed
--
-- Notably, open → raiding is intentionally absent: start_raid requires v_confirmed > 0, so this direct path is structurally unreachable.
--
-- Trigger ordering note: PostgreSQL fires BEFORE UPDATE triggers alphabetically. trg_refresh_host_action_at (r) fires before trg_validate_raid_status (v). If host_action_at raises, validate_raid_status won't fire for that row. This is safe: both roll back the transaction on exception.

CREATE OR REPLACE FUNCTION public.validate_raid_status()
RETURNS trigger AS $$
BEGIN
  -- Allow no-op updates
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- Allowed transitions
  IF OLD.status = 'open' AND (NEW.status = 'lobby' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'lobby' AND (NEW.status = 'open' OR NEW.status = 'raiding' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.status = 'raiding' AND (NEW.status = 'completed' OR NEW.status = 'cancelled') THEN
    RETURN NEW;
  END IF;

  -- Block all other transitions
  RAISE EXCEPTION 'Invalid raid status transition: % -> %', OLD.status, NEW.status
    USING ERRCODE = '23514';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_raid_status ON public.raids;
CREATE TRIGGER trg_validate_raid_status
  BEFORE UPDATE ON public.raids
  FOR EACH ROW EXECUTE FUNCTION public.validate_raid_status();
