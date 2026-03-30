-- Force PostgREST to reload its schema cache.
-- After 20260330120000 made raid_queues.raid_id nullable, PostgREST must
-- recognise the change so embedded queries automatically LEFT-JOIN raids.
NOTIFY pgrst, 'reload schema';
