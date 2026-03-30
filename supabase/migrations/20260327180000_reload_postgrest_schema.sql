-- Force PostgREST to reload schema metadata after RPC signature changes.
-- This ensures function return-shape updates are visible immediately.

NOTIFY pgrst, 'reload schema';