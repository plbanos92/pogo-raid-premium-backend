# API Guide — Pogo Raid Premium (Production)

## Base URL
```
https://jkzbruimweyolcgjmram.supabase.co
```

## Keys
| Key | When to use |
|-----|-------------|
| `anon` | Client-side requests (safe to expose in frontend, controlled by RLS) |
| `service_role` | Server-side / admin only — **never expose in frontend or commit to repo** |

Set these as env variables (see `.env.example`). The examples below use `$SUPABASE_URL` and `$SUPABASE_ANON_KEY`.

---

## 1) Authentication

### Sign up
```bash
curl -X POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"supersecret"}'
```

### Sign in (email + password)
```bash
curl -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"supersecret"}'
```
Response includes `access_token` — use this as `Bearer` token in all subsequent requests.

---

## 2) Profiles

### Create own profile
```bash
curl -X POST "$SUPABASE_URL/rest/v1/user_profiles" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"auth_id":"<your-auth-uid>","display_name":"Trainer Red"}'
```

### Read own profile
```bash
curl "$SUPABASE_URL/rest/v1/user_profiles?auth_id=eq.<your-auth-uid>&select=*" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN"
```

### Update display name
```bash
curl -X PATCH "$SUPABASE_URL/rest/v1/user_profiles?auth_id=eq.<your-auth-uid>" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"display_name":"Trainer Blue"}'
```

---

## 3) Raid Bosses (reference data, read-only)

```bash
curl "$SUPABASE_URL/rest/v1/raid_bosses?select=*&order=tier.desc" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN"
```

---

## 4) Raids

### List active raids
```bash
curl "$SUPABASE_URL/rest/v1/raids?is_active=eq.true&select=*,raid_bosses(name,tier)&order=start_time.asc" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN"
```

### Create a raid (as host)
```bash
curl -X POST "$SUPABASE_URL/rest/v1/raids" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{
    "host_user_id":"<your-auth-uid>",
    "raid_boss_id":"00000000-0000-0000-0000-000000000101",
    "location_name":"Shibuya Crossing Gym",
    "lat":35.6595,
    "lng":139.7005,
    "start_time":"2026-04-01T10:00:00Z",
    "end_time":"2026-04-01T10:45:00Z",
    "capacity":20
  }'
```

---

## 5) Queue — RPC calls

All queue actions use the `/rest/v1/rpc/<function>` endpoint with a POST and a JSON body.

### Join a raid queue
```bash
curl -X POST "$SUPABASE_URL/rest/v1/rpc/join_raid_queue" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_raid_id":"<raid-uuid>","p_note":"Ready to battle!"}'
```

Response: the created or existing `raid_queues` row.

### Host: invite next in queue
```bash
curl -X POST "$SUPABASE_URL/rest/v1/rpc/host_invite_next_in_queue" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $HOST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_raid_id":"<raid-uuid>"}'
```

Response: the invited `raid_queues` row (status → `invited`).

### Host: confirm / update queue status
```bash
curl -X POST "$SUPABASE_URL/rest/v1/rpc/host_update_queue_status" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $HOST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_queue_id":"<queue-row-uuid>","p_status":"confirmed"}'
```

Valid `p_status` values: `queued` `invited` `confirmed` `declined` `cancelled` `left`

---

## 6) Activity Logs

### Insert own log entry
```bash
curl -X POST "$SUPABASE_URL/rest/v1/activity_logs" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"<your-auth-uid>","action":"raid_joined","meta":{"raid_id":"<uuid>"}}'
```

### Read own logs
```bash
curl "$SUPABASE_URL/rest/v1/activity_logs?user_id=eq.<your-auth-uid>&order=created_at.desc&limit=20" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_TOKEN"
```

---

## JavaScript / TypeScript quick start

Install the client:
```bash
npm install @supabase/supabase-js
```

```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_ANON_KEY!
)

// Sign in
const { data: { session } } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'supersecret',
})

// List active raids
const { data: raids } = await supabase
  .from('raids')
  .select('*, raid_bosses(name, tier)')
  .eq('is_active', true)
  .order('start_time', { ascending: true })

// Join queue via RPC
const { data: queueRow, error } = await supabase.rpc('join_raid_queue', {
  p_raid_id: '<raid-uuid>',
  p_note: 'Ready to battle!',
})
```

---

## Common errors

| HTTP | Meaning | Fix |
|------|---------|-----|
| 401  | Missing or expired token | Re-authenticate and use new access_token |
| 403  | RLS policy blocked the request | Check you're acting as the correct user role |
| 409  | Unique constraint violation (e.g. already in queue) | You are already enrolled; no action needed |
| 422  | CHECK constraint violated (e.g. queue full, bad status) | Check capacity / valid status values |
| 500  | RPC raised EXCEPTION | Read the `message` field in the response body |
