-- Enable pg_net extension required by Supabase Cron for HTTP request jobs.
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
