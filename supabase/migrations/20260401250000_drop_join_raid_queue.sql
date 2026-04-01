-- Phase 3: Remove join_raid_queue RPC.
-- join_boss_queue now inlines all queue-join logic directly (migration 20260401240000).
-- No frontend caller remains (Phase 2 removed both .catch() fallback paths).
-- Dropping the function closes the surface entirely.

REVOKE EXECUTE ON FUNCTION public.join_raid_queue(uuid, text) FROM authenticated;
DROP FUNCTION IF EXISTS public.join_raid_queue(uuid, text);
