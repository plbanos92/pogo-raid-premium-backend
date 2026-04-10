\set ON_ERROR_STOP on

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- Phase 4 smoke tests: egg lobby hatch RPCs
--
-- Tests:
--   1.  No boss-queue assignment on egg INSERT
--   2.  Boss-queue entry stays boss-level during egg phase
--   3.  hatch_raid as host — happy path (status, status_changed_at, boss-queue promoted)
--   4.  hatch_raid as non-host — raises not_host
--   5.  hatch_raid on non-egg raid — raises raid_not_egg
--   6.  auto_hatch_expired_eggs — within 2-minute window (returns 1, raid open)
--   7.  auto_hatch_expired_eggs — outside 2-minute window (returns 0, raid stays egg)
--   8.  auto_hatch_expired_eggs — past hatch_time (returns 1, raid open)
--   9.  check_host_inactivity on egg raid — returns false, raid not cancelled
--   10. expire_stale_invites on egg raid — returns 0 immediately
--
-- Run with:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -f supabase/tests/04_egg_lobby.sql
-- ─────────────────────────────────────────────────────────────

-- ─── Auth users ──────────────────────────────────────────────
-- Required by realtime_sessions FK and for auth.uid() in RPCs.
INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
)
VALUES
  (
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-host-011@raidsync.local', '',
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    false, false
  ),
  (
    '00000000-0000-0000-0000-000000000021',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-user-021@raidsync.local', '',
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    false, false
  )
ON CONFLICT (id) DO NOTHING;

-- ─── Dedicated boss for Phase 4 tests ────────────────────────
-- Isolated from boss-301/302/304/305 fixtures used by earlier suites.
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000306', 'Egg Test Boss', 5, 997)
ON CONFLICT (id) DO NOTHING;

-- ─── Main egg raid for tests 1, 2, 3 ─────────────────────────
-- status='egg' suppresses trg_assign_boss_queue on INSERT (Phase-2 guard).
-- status_changed_at set to a known past value so test 3 can verify it was
-- bumped to ~now() by hatch_raid.
-- hatch_time far in future so auto_hatch_expired_eggs never picks it up
-- during tests 9/10.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time,
  status_changed_at
)
VALUES (
  '00000000-0000-0000-0000-000000000420',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Egg Main Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '25 minutes',
  now() - interval '10 minutes'   -- sentinel: hatch_raid must bump this
)
ON CONFLICT (id) DO NOTHING;

-- ─── Boss-level queue entry for user 021 on boss 306 ─────────
-- Inserted AFTER the egg raid to confirm the trigger did NOT auto-assign it.
INSERT INTO public.raid_queues (id, boss_id, user_id, status, position, is_vip, note)
VALUES (
  '00000000-0000-0000-0000-000000000701',
  '00000000-0000-0000-0000-000000000306',
  '00000000-0000-0000-0000-000000000021',
  'queued', 1, false, 'smoke-phase4-boss-level-entry'
)
ON CONFLICT (id) DO NOTHING;

-- ─── Egg raid for test 4 (non-host rejection) ────────────────
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time
)
VALUES (
  '00000000-0000-0000-0000-000000000421',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Egg Non-Host Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '25 minutes'
)
ON CONFLICT (id) DO NOTHING;

-- ─── Open raid for test 5 (non-egg rejection) ────────────────
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000422',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Open Non-Egg Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'open'
)
ON CONFLICT (id) DO NOTHING;

-- ─── Egg raid for test 9 (check_host_inactivity guard) ───────
-- last_host_action_at is old enough to normally trigger cancellation.
-- The egg guard in check_host_inactivity must return false before reaching
-- the inactivity logic.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time,
  last_host_action_at
)
VALUES (
  '00000000-0000-0000-0000-000000000426',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Egg Inactivity Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '25 minutes',
  now() - interval '200 seconds'
)
ON CONFLICT (id) DO NOTHING;

-- ─── Egg raid for test 10 (expire_stale_invites returns 0) ───
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time
)
VALUES (
  '00000000-0000-0000-0000-000000000427',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Egg Expire Stale Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '25 minutes'
)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

-- ─────────────────────────────────────────────────────────────
-- Test 1: No boss-queue assignment on egg INSERT
-- Verifies that assign_boss_queue_on_raid_create() early-returns
-- for status='egg' (Phase-2 trigger guard).
-- ─────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-000000000420';

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      'Test 1 FAILED: egg INSERT should not auto-assign boss-queue entries, found % rows',
      v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 1: no boss-queue assignment on egg INSERT — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 2: Boss-queue entry stays boss-level during egg phase
-- ─────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_entry public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_entry
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-000000000701';

  IF v_entry.raid_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Test 2 FAILED: boss-level entry should have raid_id IS NULL during egg phase, got %',
      v_entry.raid_id;
  END IF;

  IF v_entry.status <> 'queued' THEN
    RAISE EXCEPTION
      'Test 2 FAILED: boss-level entry should have status=queued during egg phase, got %',
      v_entry.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 2: boss-queue entry stays boss-level during egg phase — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 3: hatch_raid as host — happy path
-- Verifies: status=open, status_changed_at bumped,
-- and trg_assign_boss_queue_on_hatch promotes the boss-level entry.
-- ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_sentinel_ts timestamptz;
  v_raid        public.raids%ROWTYPE;
  v_entry       public.raid_queues%ROWTYPE;
BEGIN
  -- Capture status_changed_at before hatch to prove it was bumped.
  SELECT status_changed_at INTO v_sentinel_ts
  FROM public.raids
  WHERE id = '00000000-0000-0000-0000-000000000420';

  PERFORM public.hatch_raid('00000000-0000-0000-0000-000000000420');

  SELECT * INTO v_raid FROM public.raids WHERE id = '00000000-0000-0000-0000-000000000420';

  IF v_raid.status <> 'open' THEN
    RAISE EXCEPTION
      'Test 3 FAILED: hatch_raid should transition egg→open, got %', v_raid.status;
  END IF;

  IF v_raid.status_changed_at IS NULL OR v_raid.status_changed_at <= v_sentinel_ts THEN
    RAISE EXCEPTION
      'Test 3 FAILED: hatch_raid should bump status_changed_at (was %, now %)',
      v_sentinel_ts, v_raid.status_changed_at;
  END IF;

  -- trg_assign_boss_queue_on_hatch fires on egg→open and promotes
  -- boss-level queue entries (raid_id IS NULL, status='queued') for boss 306.
  SELECT * INTO v_entry
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-000000000701';

  IF v_entry.status <> 'invited' THEN
    RAISE EXCEPTION
      'Test 3 FAILED: boss-queue entry should be status=invited after hatch, got %',
      v_entry.status;
  END IF;

  IF v_entry.raid_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000420'::uuid THEN
    RAISE EXCEPTION
      'Test 3 FAILED: boss-queue entry raid_id should be 420 after hatch, got %',
      v_entry.raid_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 3: hatch_raid as host happy path — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 4: hatch_raid as non-host — raises not_host
-- ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.hatch_raid('00000000-0000-0000-0000-000000000421');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'not_host' THEN
      v_caught := true;
    ELSE
      RAISE EXCEPTION
        'Test 4 FAILED: expected not_host exception, got SQLSTATE=% SQLERRM=%',
        SQLSTATE, SQLERRM;
    END IF;
  END;

  IF NOT v_caught THEN
    RAISE EXCEPTION
      'Test 4 FAILED: hatch_raid by non-host should raise not_host but no exception was raised';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 4: hatch_raid as non-host rejected — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 5: hatch_raid on non-egg raid — raises raid_not_egg
-- ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.hatch_raid('00000000-0000-0000-0000-000000000422');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'raid_not_egg%' THEN
      v_caught := true;
    ELSE
      RAISE EXCEPTION
        'Test 5 FAILED: expected raid_not_egg exception, got SQLSTATE=% SQLERRM=%',
        SQLSTATE, SQLERRM;
    END IF;
  END;

  IF NOT v_caught THEN
    RAISE EXCEPTION
      'Test 5 FAILED: hatch_raid on open raid should raise raid_not_egg but no exception was raised';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 5: hatch_raid on non-egg raid rejected — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 6: auto_hatch_expired_eggs — within 2-minute window
-- Creates a fresh egg raid with hatch_time = now() + 1 minute,
-- isolated via SAVEPOINT so the return count is exactly 1.
-- ─────────────────────────────────────────────────────────────

SAVEPOINT test6;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time
)
VALUES (
  '00000000-0000-0000-0000-000000000423',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Auto Hatch 1min Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '1 minute'
);

DO $$
DECLARE
  v_count  int;
  v_status text;
BEGIN
  SELECT public.auto_hatch_expired_eggs() INTO v_count;

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Test 6 FAILED: expected auto_hatch_expired_eggs()=1, got %', v_count;
  END IF;

  SELECT status INTO v_status
  FROM public.raids WHERE id = '00000000-0000-0000-0000-000000000423';

  IF v_status <> 'open' THEN
    RAISE EXCEPTION
      'Test 6 FAILED: egg raid with hatch_time +1min should be open, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 6: auto_hatch_expired_eggs within 2-min window — PASSED'; END; $$;

ROLLBACK TO SAVEPOINT test6;
RELEASE SAVEPOINT test6;

-- ─────────────────────────────────────────────────────────────
-- Test 7: auto_hatch_expired_eggs — outside 2-minute window
-- Creates a fresh egg raid with hatch_time = now() + 10 minutes,
-- isolated via SAVEPOINT so the return count is exactly 0.
-- ─────────────────────────────────────────────────────────────

SAVEPOINT test7;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time
)
VALUES (
  '00000000-0000-0000-0000-000000000424',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Auto Hatch 10min Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'egg',
  now() + interval '10 minutes'
);

DO $$
DECLARE
  v_count  int;
  v_status text;
BEGIN
  SELECT public.auto_hatch_expired_eggs() INTO v_count;

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      'Test 7 FAILED: expected auto_hatch_expired_eggs()=0 for far-future hatch_time, got %',
      v_count;
  END IF;

  SELECT status INTO v_status
  FROM public.raids WHERE id = '00000000-0000-0000-0000-000000000424';

  IF v_status <> 'egg' THEN
    RAISE EXCEPTION
      'Test 7 FAILED: egg raid with hatch_time +10min should stay egg, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 7: auto_hatch_expired_eggs outside 2-min window — PASSED'; END; $$;

ROLLBACK TO SAVEPOINT test7;
RELEASE SAVEPOINT test7;

-- ─────────────────────────────────────────────────────────────
-- Test 8: auto_hatch_expired_eggs — past hatch_time
-- Creates a fresh egg raid with hatch_time = now() - 5 minutes,
-- isolated via SAVEPOINT so the return count is exactly 1.
-- ─────────────────────────────────────────────────────────────

SAVEPOINT test8;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status, hatch_time
)
VALUES (
  '00000000-0000-0000-0000-000000000425',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000306',
  'Auto Hatch Past Gym',
  now() - interval '5 minutes',
  now() + interval '55 minutes',
  3, true, 'egg',
  now() - interval '5 minutes'
);

DO $$
DECLARE
  v_count  int;
  v_status text;
BEGIN
  SELECT public.auto_hatch_expired_eggs() INTO v_count;

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Test 8 FAILED: expected auto_hatch_expired_eggs()=1 for past hatch_time, got %',
      v_count;
  END IF;

  SELECT status INTO v_status
  FROM public.raids WHERE id = '00000000-0000-0000-0000-000000000425';

  IF v_status <> 'open' THEN
    RAISE EXCEPTION
      'Test 8 FAILED: egg raid with past hatch_time should be open, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 8: auto_hatch_expired_eggs past hatch_time — PASSED'; END; $$;

ROLLBACK TO SAVEPOINT test8;
RELEASE SAVEPOINT test8;

-- ─────────────────────────────────────────────────────────────
-- Test 9: check_host_inactivity on egg raid — not cancelled
-- Raid 426 has last_host_action_at old enough to normally trigger
-- cancellation, but the egg guard must return false before reaching
-- the inactivity logic.
-- ─────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_result boolean;
  v_status text;
BEGIN
  SELECT public.check_host_inactivity('00000000-0000-0000-0000-000000000426') INTO v_result;

  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION
      'Test 9 FAILED: check_host_inactivity on egg should return false, got %', v_result;
  END IF;

  SELECT status INTO v_status
  FROM public.raids WHERE id = '00000000-0000-0000-0000-000000000426';

  IF v_status <> 'egg' THEN
    RAISE EXCEPTION
      'Test 9 FAILED: egg raid should NOT be cancelled by check_host_inactivity, got status=%',
      v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 9: check_host_inactivity on egg raid not cancelled — PASSED'; END; $$;

-- ─────────────────────────────────────────────────────────────
-- Test 10: expire_stale_invites on egg raid — returns 0 immediately
-- Egg raids have no invited entries; the early-exit path returns 0
-- before reaching the egg-guard branch.
-- ─────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000427') INTO v_count;

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      'Test 10 FAILED: expire_stale_invites on egg should return 0, got %', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'Test 10: expire_stale_invites on egg raid returns 0 — PASSED'; END; $$;

ROLLBACK;
