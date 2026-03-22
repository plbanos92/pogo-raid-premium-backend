# CRUD Smoke Checklist (Manual)

Use these checks before integrating frontend flows.

## 1) Environment readiness
- Run: supabase start
- Run: supabase db reset --local
- Confirm API URL and anon key from local output.

## 2) Basic reads
- GET /rest/v1/raid_bosses?select=*
- GET /rest/v1/raids?select=*&is_active=eq.true

Expected:
- raid_bosses returns seeded rows.
- raids visibility follows RLS and auth context.

## 3) Basic user-scoped CRUD
- Authenticate test user.
- INSERT own profile in user_profiles.
- SELECT own profile.
- UPDATE own profile display_name.
- DELETE own profile (optional).

Expected:
- All own-row operations pass.
- Cross-user operations are denied.

## 4) Queue flow via RPC
- Call rpc/join_raid_queue with p_raid_id.
- Host user calls rpc/host_invite_next_in_queue.
- Host updates queue state via rpc/host_update_queue_status.

Expected:
- Capacity checks enforced.
- Host ownership checks enforced.
- State transitions persisted.

## 5) Audit checks
- INSERT activity_logs for current user.
- SELECT own activity_logs.

Expected:
- Own rows visible.
- Other users' logs not visible.
