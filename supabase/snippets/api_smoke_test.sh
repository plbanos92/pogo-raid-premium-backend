#!/usr/bin/env bash
# =============================================================================
# Pogo Raid Premium — Live API smoke test script
# Run from any shell (bash/zsh on Linux/Mac, Git Bash on Windows)
# Prerequisites: curl, jq (optional — for pretty output)
# =============================================================================

SUPABASE_URL="https://jkzbruimweyolcgjmram.supabase.co"
# The anon key below is the public client key — safe to use here.
# Retrieve it at any time with:
#   supabase projects api-keys --project-ref jkzbruimweyolcgjmram
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpremJydWltd2V5b2xjZ2ptcmFtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMjA0MjMsImV4cCI6MjA4ODc5NjQyM30.cV39soOyyuy0NDRP6cw9jlEWIQ8raclS-WMEnmdp8-g"

# Helper: print section header
section() { echo; echo "===== $1 ====="; }

# -----------------------------------------------------------------
# 1. HOW THE ANON KEY IS GENERATED
# -----------------------------------------------------------------
# The anon key is a JWT signed by Supabase using your project's
# JWT secret. It is created automatically when the project is made.
# You do NOT generate it yourself.
#
# Decode it to see its claims (no secret needed — JWT header+payload is plain base64):
section "Anon key decoded (header + payload)"
echo "$ANON_KEY" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null || \
  echo "$ANON_KEY" | cut -d. -f2 | base64 --decode 2>/dev/null || \
  echo "(base64 decode: install python3 or run below manually)"
echo ""
echo "Key fields in the token:"
echo "  role : anon       (tells PostgREST this is an anonymous request)"
echo "  ref  : jkzbruimweyolcgjmram  (ties it to this specific project)"
echo "  exp  : 2088796423  (far-future expiry — Supabase API keys don't expire)"
echo ""
echo "Retrieve fresh key any time with:"
echo "  supabase projects api-keys --project-ref jkzbruimweyolcgjmram"

# -----------------------------------------------------------------
# 2. UNAUTHENTICATED — Raid Bosses (no RLS, seed data visible)
# -----------------------------------------------------------------
section "GET /rest/v1/raid_bosses"
curl -s "$SUPABASE_URL/rest/v1/raid_bosses?select=id,name,tier,pokemon_id&order=tier.desc" \
  -H "apikey: $ANON_KEY" | python3 -m json.tool 2>/dev/null || \
curl -s "$SUPABASE_URL/rest/v1/raid_bosses?select=id,name,tier,pokemon_id&order=tier.desc" \
  -H "apikey: $ANON_KEY"

# -----------------------------------------------------------------
# 3. SIGN UP A TEST USER — captures access_token for all below
# -----------------------------------------------------------------
section "POST /auth/v1/signup"
SIGNUP_RESPONSE=$(curl -s -X POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"smoketest@pogo-test.dev","password":"TestPass123!"}')
echo "$SIGNUP_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$SIGNUP_RESPONSE"

ACCESS_TOKEN=$(echo "$SIGNUP_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
USER_ID=$(echo "$SIGNUP_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo ""
echo "Extracted access_token: ${ACCESS_TOKEN:0:40}..."
echo "Extracted user id     : $USER_ID"

# If user already exists, sign in instead
if [ -z "$ACCESS_TOKEN" ]; then
  section "User exists — signing in"
  SIGNIN_RESPONSE=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" \
    -d '{"email":"smoketest@pogo-test.dev","password":"TestPass123!"}')
  echo "$SIGNIN_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$SIGNIN_RESPONSE"
  ACCESS_TOKEN=$(echo "$SIGNIN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  USER_ID=$(echo "$SIGNIN_RESPONSE" | grep -o '"user":{[^}]*"id":"[^"]*"' | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
fi

# -----------------------------------------------------------------
# 4. CREATE OWN PROFILE
# -----------------------------------------------------------------
section "POST /rest/v1/user_profiles"
curl -s -X POST "$SUPABASE_URL/rest/v1/user_profiles" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"auth_id\":\"$USER_ID\",\"display_name\":\"Smoke Tester\"}" \
  | python3 -m json.tool 2>/dev/null || \
curl -s "$SUPABASE_URL/rest/v1/user_profiles" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ACCESS_TOKEN"

# -----------------------------------------------------------------
# 5. READ OWN PROFILE
# -----------------------------------------------------------------
section "GET /rest/v1/user_profiles (own)"
curl -s "$SUPABASE_URL/rest/v1/user_profiles?auth_id=eq.$USER_ID&select=*" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | python3 -m json.tool 2>/dev/null || \
curl -s "$SUPABASE_URL/rest/v1/user_profiles?auth_id=eq.$USER_ID&select=*" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# -----------------------------------------------------------------
# 6. LIST ACTIVE RAIDS (RLS requires auth)
# -----------------------------------------------------------------
section "GET /rest/v1/raids (active)"
curl -s "$SUPABASE_URL/rest/v1/raids?is_active=eq.true&select=id,location_name,start_time,capacity&order=start_time.asc" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | python3 -m json.tool 2>/dev/null || \
curl -s "$SUPABASE_URL/rest/v1/raids?is_active=eq.true&select=id,location_name,start_time,capacity&order=start_time.asc" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# -----------------------------------------------------------------
# 7. RPC — join_raid_queue (use seed raid id)
# Replace the p_raid_id below with a real UUID from step 6 above.
# -----------------------------------------------------------------
SEED_RAID_ID="00000000-0000-0000-0000-000000000201"
section "POST /rest/v1/rpc/join_raid_queue"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/join_raid_queue" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_raid_id\":\"$SEED_RAID_ID\",\"p_note\":\"smoke test join\"}" \
  | python3 -m json.tool 2>/dev/null || \
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/join_raid_queue" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_raid_id\":\"$SEED_RAID_ID\",\"p_note\":\"smoke test join\"}"

echo ""
echo "=== Smoke test complete ==="
