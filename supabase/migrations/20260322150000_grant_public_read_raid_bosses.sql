-- Grant unauthenticated and authenticated read access on raid_bosses.
-- raid_bosses is public reference data; no RLS needed, but we still need
-- explicit GRANT so PostgREST exposes the table to the anon role.

GRANT SELECT ON TABLE public.raid_bosses TO anon, authenticated;
