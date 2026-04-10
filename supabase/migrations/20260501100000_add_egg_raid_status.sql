-- Phase 1: Egg Lobby Hosting — Schema Extension
-- Adds 'egg' to raid_status_enum and a hatch_time column to raids.
-- This is purely additive — no existing code uses 'egg'; no triggers change.
-- The enum value is irreversible but dormant until used in Phase 2+.

-- Extend raid_status_enum with 'egg' value
ALTER TYPE public.raid_status_enum ADD VALUE IF NOT EXISTS 'egg';

-- Add hatch_time for egg lobby countdown (set by host; not auto-triggering at DB level)
ALTER TABLE public.raids
  ADD COLUMN IF NOT EXISTS hatch_time timestamptz NULL;

COMMENT ON COLUMN public.raids.hatch_time IS
  'Expected hatch timestamp for egg lobbies. The lobby transitions egg→open (and invites are sent) 2 minutes before this time, giving joiners time to send friend requests in-game before the raid starts. NULL means the host must open the lobby manually.';
