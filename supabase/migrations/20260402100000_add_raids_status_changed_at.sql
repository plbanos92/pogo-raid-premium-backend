-- Add status_changed_at to raids: only updates when the status column changes.
-- Purpose: gives the sync cursor a raid-status-specific version stamp that is
-- immune to touch_host_activity heartbeats (which only touch last_host_action_at).
-- Using updated_at would cause false-positive refreshData() calls every ~10 s
-- for all idle polling-mode users whenever any host is active (HOT_MS = 10 s).

ALTER TABLE public.raids
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz NOT NULL DEFAULT now();

-- Backfill: use updated_at as the starting value for all existing rows.
-- NOTE: This UPDATE fires trg_raids_set_updated_at which bumps updated_at = now()
-- on every raids row. This causes a one-time cursor change for hostedRaidsVersion
-- and myQueuesVersion, triggering one extra refreshData() per active session after
-- migration. This is harmless and self-resolving (identical to the deploy-time
-- false-positive documented in Phase 2).
UPDATE public.raids SET status_changed_at = updated_at WHERE TRUE;

-- Conditional trigger: only fires when status actually changes.
CREATE OR REPLACE FUNCTION public.trg_fn_raids_status_changed_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_changed_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_raids_status_changed_at ON public.raids;
CREATE TRIGGER trg_raids_status_changed_at
  BEFORE UPDATE ON public.raids
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_fn_raids_status_changed_at();

-- Partial index for efficient MAX(status_changed_at) scan over non-terminal raids.
-- No existing index confirmed by migration audit.
CREATE INDEX IF NOT EXISTS idx_raids_status_changed_at
  ON public.raids (status_changed_at)
  WHERE status NOT IN ('completed', 'cancelled');
