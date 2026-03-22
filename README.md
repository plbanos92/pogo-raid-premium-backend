# pogo-raid-premium-backend

Supabase backend for raid queue MVP.

## Prerequisites
- Docker Desktop
- Supabase CLI

## Local setup
1. Start local Supabase stack:
   supabase start
2. Apply migrations and seed data:
   supabase db reset --local
3. Run SQL smoke checks:
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/01_rpc_and_rls.sql

## Core folders
- supabase/migrations: schema and RPC migrations
- supabase/seed.sql: baseline local fixtures
- supabase/tests: SQL smoke/policy checks
- supabase/snippets: manual API walkthroughs

## Further reading
- [supabase/snippets/API_GUIDE.md](supabase/snippets/API_GUIDE.md) — how to call every production API endpoint (REST + RPC), with curl and JS examples
- [ENVIRONMENTS.md](ENVIRONMENTS.md) — how to set up and target dev/staging/prod environments using separate Supabase projects or Branching
- [supabase/snippets/CRUD_SMOKE_CHECKLIST.md](supabase/snippets/CRUD_SMOKE_CHECKLIST.md) — manual pre-integration checklist

## Notes
- RLS is enabled; most API calls require an authenticated JWT (`access_token` from sign-in).
- Use the `anon` key on the client and the `service_role` key only on the server — never expose the service_role key in frontend code.
- Prefer RPC functions for host actions and queue transitions to ensure transactional safety.
- Copy `.env.example` to `.env.local` (or `.env.production`) and fill in your project credentials.
