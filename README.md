# pogo-raid-premium-backend

Supabase backend for raid queue MVP.

## Current status
- MVP-ready for trial usage on the linked production Supabase project.
- Core queue lifecycle is implemented with transactional RPCs.
- Live API smoke test is available for Windows via PowerShell script.
- Public raid boss reference read is enabled for anon/authenticated clients.

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

## Production smoke test (Windows PowerShell)
1. Fill `supabase/snippets/.env.smoke.local` with:
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `SMOKE_TEST_EMAIL`
   - `SMOKE_TEST_PASSWORD`
2. Run:
   .\\supabase\\snippets\\api_smoke_test.ps1

Notes:
- The script auto-loads values from `.env.smoke.local` into process env vars.
- The script restores/clears loaded env vars at the end (even on failure).
- `supabase/snippets/.env.smoke.local` is gitignored and must never be committed.

## Core folders
- supabase/migrations: schema and RPC migrations
- supabase/seed.sql: baseline local fixtures
- supabase/tests: SQL smoke/policy checks
- supabase/snippets: manual API walkthroughs

## Further reading
- [supabase/snippets/API_GUIDE.md](supabase/snippets/API_GUIDE.md) — how to call every production API endpoint (REST + RPC), with curl and JS examples
- [supabase/snippets/api_smoke_test.ps1](supabase/snippets/api_smoke_test.ps1) — end-to-end live API smoke test for Windows PowerShell
- [SUPABASE_DEPLOYMENT_GUIDE.md](SUPABASE_DEPLOYMENT_GUIDE.md) — script-based deployment workflow for staging/production with verification and smoke-test options
- [ENVIRONMENTS.md](ENVIRONMENTS.md) — how to set up and target dev/staging/prod environments using separate Supabase projects or Branching
- [supabase/snippets/CRUD_SMOKE_CHECKLIST.md](supabase/snippets/CRUD_SMOKE_CHECKLIST.md) — manual pre-integration checklist
- [supabase/MVP_READINESS_ASSESSMENT.md](supabase/MVP_READINESS_ASSESSMENT.md) — readiness assessment and remaining hardening recommendations

## Notes
- RLS is enabled; most API calls require an authenticated JWT (`access_token` from sign-in).
- Use the `anon` key on the client and the `service_role` key only on the server — never expose the service_role key in frontend code.
- Prefer RPC functions for host actions and queue transitions to ensure transactional safety.
- Copy `.env.example` to `.env.local` (or `.env.production`) and fill in your project credentials.
