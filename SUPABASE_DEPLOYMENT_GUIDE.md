# Supabase Remote Deployment Guide

This guide describes how to deploy backend changes (migrations and optional seed) to remote Supabase using repository scripts.

## Scripts

- `scripts/supabase-deploy.ps1`
- `scripts/supabase-status.ps1`

## When to use each script

Use `scripts/supabase-status.ps1` when you want to inspect migration state only.

Typical cases:
- Before deployment, to confirm what is pending remotely.
- After deployment, to confirm local and remote are in sync.
- During incident/debug sessions, to quickly verify whether schema drift exists.

Use `scripts/supabase-deploy.ps1` when you want to apply changes remotely.

Typical cases:
- You added/updated migration SQL and need to apply it to staging or production.
- You want to include seed data (`-IncludeSeed`) for non-production refreshes.
- You want to deploy and then immediately validate API health (`-RunSmokeTest`).

Quick rule:
- Read-only check -> `supabase-status.ps1`
- Apply database changes -> `supabase-deploy.ps1`

## What the deploy script does

Script: `scripts/supabase-deploy.ps1`

1. Validates `supabase` CLI is installed.
2. Validates target environment input:
   - either `-ProjectRef <ref>`
   - or `-Linked` (use current linked project)
3. Runs migration deploy:
   - `supabase db push --project-ref <ref>`
   - or `supabase db push --linked`
4. Optionally includes seed data when `-IncludeSeed` is passed.
5. Verifies deployment by running migration status:
   - `supabase migration list --project-ref <ref>`
   - or `supabase migration list --linked`
6. Optionally runs end-to-end API smoke test when `-RunSmokeTest` is passed.

## What the status script does

Script: `scripts/supabase-status.ps1`

1. Validates `supabase` CLI is installed.
2. Validates target environment input (`-ProjectRef` or `-Linked`).
3. Runs `supabase migration list ...` to show local vs remote migration sync.

## Prerequisites

1. Supabase CLI installed and authenticated (`supabase login`).
2. Correct project refs for your environments.
3. For smoke test option:
   - fill `supabase/snippets/.env.smoke.local`
   - include `SUPABASE_SERVICE_ROLE_KEY`, `SMOKE_TEST_EMAIL`, `SMOKE_TEST_PASSWORD`

## Step-by-step: when you add a table or change a column

Use this flow for any schema change.

1. Create a new migration file (never edit old migrations already pushed):

```powershell
supabase migration new add_table_or_column_change
```

2. Edit the generated SQL file in `supabase/migrations`.

3. Rebuild local DB from migrations and seed:

```powershell
supabase db reset --local
```

4. Optional local SQL smoke checks:

```powershell
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/01_rpc_and_rls.sql
```

5. Check current remote status before deploy:

```powershell
.\scripts\supabase-status.ps1 -Linked
```

6. Deploy schema changes to remote:

```powershell
.\scripts\supabase-deploy.ps1 -Linked
```

7. Verify remote sync after deploy:

```powershell
.\scripts\supabase-status.ps1 -Linked
```

8. Optional deploy and smoke validation in one run:

```powershell
.\scripts\supabase-deploy.ps1 -Linked -RunSmokeTest
```

If you also changed seed data, deploy with:

```powershell
.\scripts\supabase-deploy.ps1 -Linked -IncludeSeed
```

## Copy-paste commands

### 1) Check production migration status (linked project)

```powershell
cd C:\Users\paulo\Documents\projects\pogo\pogo-raid-premium-backend
.\scripts\supabase-status.ps1 -Linked
```

### 2) Deploy migrations to production (linked project)

```powershell
cd C:\Users\paulo\Documents\projects\pogo\pogo-raid-premium-backend
.\scripts\supabase-deploy.ps1 -Linked
```

### 3) Deploy migrations + seed to production (linked project)

```powershell
cd C:\Users\paulo\Documents\projects\pogo\pogo-raid-premium-backend
.\scripts\supabase-deploy.ps1 -Linked -IncludeSeed
```

### 4) Deploy to staging by explicit project ref

```powershell
cd C:\Users\paulo\Documents\projects\pogo\pogo-raid-premium-backend
.\scripts\supabase-deploy.ps1 -ProjectRef <staging-project-ref>
```

### 5) Deploy and run smoke test

```powershell
cd C:\Users\paulo\Documents\projects\pogo\pogo-raid-premium-backend
.\scripts\supabase-deploy.ps1 -Linked -RunSmokeTest
```

## Recommended deployment flow

1. Run CI and local checks first.
2. Deploy to staging project ref.
3. Validate staging.
4. Deploy to production (`-Linked` or explicit prod ref).
5. Run smoke test.
6. Confirm migration list is in sync.

## Troubleshooting

- `Supabase CLI not found`:
  - install/update CLI and reopen terminal.
- `Provide -ProjectRef <ref> or use -Linked`:
  - pass one of those options.
- migration errors from `db push`:
  - fix migration SQL locally, then rerun deploy.
- smoke test auth failure:
  - update `supabase/snippets/.env.smoke.local` with valid values.
