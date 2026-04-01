-- Add raids table to Supabase Realtime publication so postgres_changes
-- subscriptions on the raids table deliver events to connected clients.
-- REPLICA IDENTITY FULL is NOT needed — no row-level filter is used on this channel.
ALTER PUBLICATION supabase_realtime ADD TABLE public.raids;
