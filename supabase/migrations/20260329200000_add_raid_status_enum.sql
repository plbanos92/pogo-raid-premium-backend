-- 20260329200000_add_raid_status_enum.sql
-- Adds raid_status_enum type and status column to raids table, with backfill logic.
-- Enum values: open, lobby, raiding, completed, cancelled
--
-- Backfill logic:
--   - completed: NOT is_active AND host_finished_at IS NOT NULL
--   - cancelled: NOT is_active (and not completed)
--   - raiding: any raid_queues for this raid with status = 'raiding'
--   - lobby: any raid_queues for this raid with status = 'confirmed'
--   - open: all others

-- 1. Create enum type
CREATE TYPE raid_status_enum AS ENUM ('open', 'lobby', 'raiding', 'completed', 'cancelled');

-- 2. Add status column to raids
ALTER TABLE public.raids
  ADD COLUMN status raid_status_enum NOT NULL DEFAULT 'open';

-- 3. Backfill status for existing raids
UPDATE public.raids SET status =
  CASE
    WHEN NOT is_active AND host_finished_at IS NOT NULL
      THEN 'completed'::raid_status_enum
    WHEN NOT is_active
      THEN 'cancelled'::raid_status_enum
    WHEN EXISTS (
      SELECT 1 FROM public.raid_queues
      WHERE raid_id = raids.id AND status = 'raiding'
    ) THEN 'raiding'::raid_status_enum
    WHEN EXISTS (
      SELECT 1 FROM public.raid_queues
      WHERE raid_id = raids.id AND status = 'confirmed'
    ) THEN 'lobby'::raid_status_enum
    ELSE 'open'::raid_status_enum
  END;

-- No permissions, triggers, or constraints added in this migration.
