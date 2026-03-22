# Supabase Environments Guide

## Does Supabase support multiple environments?

Yes. Two approaches are available, and you can combine them.

---

## Approach A — Separate Projects (recommended for most teams)

Create one Supabase project per environment:

| Environment | Supabase project | Linked in CLI |
|-------------|-----------------|---------------|
| Development | `pogo-raid-premium-dev` | `supabase link --project-ref <dev-ref>` |
| Staging / UAT | `pogo-raid-premium-staging` | `supabase link --project-ref <staging-ref>` |
| Production | `pogo-raid-premium` (`jkzbruimweyolcgjmram`) | currently linked |

Each project has its own URL, anon key, and service role key.

### How to push migrations to a specific environment

```bash
# Push to staging without re-linking
supabase db push --project-ref <staging-ref>

# Push to production (currently linked)
supabase db push --linked
```

### How to seed a specific environment

```bash
supabase db push --project-ref <staging-ref> --include-seed
```

---

## Approach B — Database Branching (Pro/Team plan)

Supabase Branching creates a preview database automatically for every Git branch.
Enable it in: Supabase Dashboard → Project Settings → Branching.

- Push to a feature branch → preview branch is created and migrations run.
- Merge the PR → production runs the migration.
- No extra projects to manage, but requires a Pro/Team plan.

---

## Setting up environment variables

### 1. Create per-environment .env files

Start from the template:
```bash
cp .env.example .env.local        # local dev
cp .env.example .env.staging
cp .env.example .env.production
```

Fill in the values for each file:
```
SUPABASE_URL=https://<env-specific-ref>.supabase.co
SUPABASE_ANON_KEY=<env-anon-key>
SUPABASE_SERVICE_ROLE_KEY=<env-service-role-key>
APP_ENV=staging
```

### 2. Look up keys per project

```bash
supabase projects api-keys --project-ref <project-ref>
```

Or use the Supabase Dashboard → Project Settings → API → Project API Keys.

### 3. Local smoke-test secrets file (Windows helper)

For `supabase/snippets/api_smoke_test.ps1`, use:
- `supabase/snippets/.env.smoke.local`

Example keys in that file:
```
SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
SMOKE_TEST_EMAIL=<confirmed-test-email>
SMOKE_TEST_PASSWORD=<test-password>
```

Security notes:
- This file is local-only and is gitignored.
- The smoke script loads these into process env vars and restores/clears them after run.
- Never place service role keys in frontend environment variables.

---

## Using environment variables in app code

### Node.js / TypeScript (recommended)
```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL!,      // never hardcode
  process.env.SUPABASE_ANON_KEY!  // use env var
)
```

Load the right `.env` file via your runtime:
```bash
# Example with dotenv-cli
dotenv -e .env.staging -- node dist/server.js

# Or with tsx
NODE_ENV=staging tsx src/server.ts
```

### Cloudflare Pages / Workers (pogo-raid-premium frontend)

Variables are set in the Cloudflare Pages dashboard per deployment environment:

1. Go to Cloudflare Pages → your project → Settings → Environment Variables.
2. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` under **Preview** (staging) and **Production** separately.
3. In `wrangler.toml` you can declare environment-specific variables:

```toml
# wrangler.toml (in pogo-raid-premium frontend repo)
[vars]
SUPABASE_URL = "https://jkzbruimweyolcgjmram.supabase.co"  # fallback default

[env.staging.vars]
SUPABASE_URL = "https://<staging-ref>.supabase.co"

[env.production.vars]
SUPABASE_URL = "https://jkzbruimweyolcgjmram.supabase.co"
```

Sensitive keys (anon key, service role key) should NOT be in `wrangler.toml`.
Set them as encrypted secrets in the Cloudflare dashboard or via:
```bash
wrangler secret put SUPABASE_ANON_KEY --env staging
wrangler secret put SUPABASE_ANON_KEY --env production
```

---

## CI pipeline (GitHub Actions)

Store per-environment secrets in GitHub:
- `SUPABASE_ACCESS_TOKEN` — CLI login token (shared)
- `SUPABASE_PROJECT_REF_STAGING` — staging project ref
- `SUPABASE_PROJECT_REF_PROD` — production project ref

For manual staging deploys:
```yaml
- name: Push migrations to staging
  run: supabase db push --project-ref ${{ secrets.SUPABASE_PROJECT_REF_STAGING }}
  env:
    SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
```

For production (only on main):
```yaml
- name: Push migrations to production
  if: github.ref == 'refs/heads/main'
  run: supabase db push --project-ref ${{ secrets.SUPABASE_PROJECT_REF_PROD }}
  env:
    SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
```

---

## Summary

| Goal | What to do |
|------|-----------|
| Local dev | `supabase start` + `supabase db reset --local` |
| Deploy to staging | `supabase db push --project-ref <staging-ref>` |
| Deploy to production | `supabase db push --linked` (currently linked to prod) |
| Switch linked environment | `supabase link --project-ref <ref>` |
| App env config | Use `.env.<environment>` files + env vars in Cloudflare/CI |
