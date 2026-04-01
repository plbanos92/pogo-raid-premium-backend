-- Fix: realtime_sessions and raid_queues were not in the supabase_realtime
-- Realtime publication. Without this, ALL postgres_changes subscriptions fire
-- CHANNEL_ERROR immediately, causing every user to be demoted to polling mode
-- within milliseconds of connecting.
--
-- Additionally: DELETE events with row-level filters (user_id=eq.{uid}) require
-- REPLICA IDENTITY FULL so the OLD values are available in the WAL record.
-- Without it, filtered DELETE events on realtime_sessions are never delivered,
-- breaking the eviction-detection channel even when the table is published.

-- Add tables to the Supabase Realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.raid_queues;
ALTER PUBLICATION supabase_realtime ADD TABLE public.realtime_sessions;

-- Required for filtered DELETE event delivery on realtime_sessions
ALTER TABLE public.realtime_sessions REPLICA IDENTITY FULL;
