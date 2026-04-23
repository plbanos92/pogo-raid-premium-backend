\set ON_ERROR_STOP on

BEGIN;

-- Fixture setup executed as elevated role.
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

-- Isolated boss for join/rejoin smoke tests. Kept separate from boss 301
-- so join_boss_queue routing never contaminates boss-301 raid fixtures.
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000304', 'Join Test Boss', 5, 998)
ON CONFLICT (id) DO NOTHING;

-- Raid 414: the sole open raid for boss 304. join_boss_queue always routes here.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time,
  capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000414',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000304',
  'Join Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'open'
)
ON CONFLICT (id) DO NOTHING;

-- Terminal entries in raid 414 used by the rejoin smoke tests.
-- User 22: 'left'     — exercises the rejoin-after-left path (Test 3a).
-- User 23: 'cancelled' — exercises the rejoin-after-cancelled path (Test 3b).
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES (
  '00000000-0000-0000-0000-000000000609',
  '00000000-0000-0000-0000-000000000414',
  '00000000-0000-0000-0000-000000000022',
  'left', 1, false, 'smoke-phase3-left-rejoin-304'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES (
  '00000000-0000-0000-0000-000000000610',
  '00000000-0000-0000-0000-000000000414',
  '00000000-0000-0000-0000-000000000023',
  'cancelled', 2, false, 'smoke-phase3-cancelled-rejoin-304'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Inactive Test Gym',
  now() - interval '90 minutes',
  now() - interval '30 minutes',
  3,
  false
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000403',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Invite Test Gym',
  now() + interval '45 minutes',
  now() + interval '105 minutes',
  3,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (
  id,
  raid_id,
  user_id,
  status,
  position,
  is_vip,
  note
)
VALUES (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000021',
  'done',
  1,
  false,
  'smoke-inactive-raid-visibility'
)
ON CONFLICT (id) DO NOTHING;

-- Seed the queued companion row used by the leave auto-fill regression.
INSERT INTO public.raid_queues (
  id,
  raid_id,
  user_id,
  status,
  position,
  is_vip,
  note
)
VALUES (
  '00000000-0000-0000-0000-000000000503',
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000022',
  'queued',
  2,
  false,
  'smoke-leave-autofill'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000405',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Leave Test Gym',
  now() + interval '75 minutes',
  now() + interval '135 minutes',
  2,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (
  id,
  raid_id,
  user_id,
  status,
  position,
  is_vip,
  note
)
VALUES
  (
    '00000000-0000-0000-0000-000000000605',
    '00000000-0000-0000-0000-000000000405',
    '00000000-0000-0000-0000-000000000025',
    'invited',
    1,
    false,
    'smoke-leave-invited'
  ),
  (
    '00000000-0000-0000-0000-000000000606',
    '00000000-0000-0000-0000-000000000405',
    '00000000-0000-0000-0000-000000000026',
    'queued',
    2,
    false,
    'smoke-leave-queued'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000404',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Cancel Test Gym',
  now() + interval '60 minutes',
  now() + interval '120 minutes',
  3,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (
  id,
  raid_id,
  user_id,
  status,
  position,
  is_vip,
  note
)
VALUES
  (
    '00000000-0000-0000-0000-000000000603',
    '00000000-0000-0000-0000-000000000404',
    '00000000-0000-0000-0000-000000000023',
    'invited',
    1,
    false,
    'smoke-cancel-invited'
  ),
  (
    '00000000-0000-0000-0000-000000000604',
    '00000000-0000-0000-0000-000000000404',
    '00000000-0000-0000-0000-000000000024',
    'queued',
    2,
    false,
    'smoke-cancel-queued'
  )
ON CONFLICT (id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────
-- Phase 3 fixtures: status-predicate regression test data
-- ─────────────────────────────────────────────────────────────

-- Dedicated boss so the boss-queue test is isolated from boss 301 raids.
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000302', 'Phase3 Boss', 5, 900)
ON CONFLICT (id) DO NOTHING;

-- Raid in 'raiding' state with is_active=true: join_boss_queue must reject it.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time,
  capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000406',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000302',
  'Phase3 Raiding Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'raiding'
)
ON CONFLICT (id) DO NOTHING;

-- Raid with is_active=true but status='completed': join_boss_queue must not join it
-- (tests that the status predicate — not is_active — gates joinability).
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time,
  capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000407',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Phase3 Completed Gym',
  now() - interval '90 minutes',
  now() - interval '30 minutes',
  3, true, 'completed'
)
ON CONFLICT (id) DO NOTHING;

-- Raid with is_active=true but status='cancelled': same intent as above.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time,
  capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000408',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Phase3 Cancelled Gym',
  now() - interval '90 minutes',
  now() - interval '30 minutes',
  3, true, 'cancelled'
)
ON CONFLICT (id) DO NOTHING;

-- Open raid used as the re-join target.
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time,
  capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000409',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Phase3 Rejoin Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3, true, 'open'
)
ON CONFLICT (id) DO NOTHING;

-- Pre-existing 'left' entry for user 21 in the rejoin raid.
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES (
  '00000000-0000-0000-0000-000000000607',
  '00000000-0000-0000-0000-000000000409',
  '00000000-0000-0000-0000-000000000021',
  'left', 1, false, 'smoke-phase3-left-rejoin'
)
ON CONFLICT (id) DO NOTHING;

-- Pre-existing 'cancelled' entry for user 22 in the rejoin raid.
-- Tests that a user whose slot was cancelled can also re-enroll.
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES (
  '00000000-0000-0000-0000-000000000608',
  '00000000-0000-0000-0000-000000000409',
  '00000000-0000-0000-0000-000000000022',
  'cancelled', 2, false, 'smoke-phase3-cancelled-rejoin'
)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;

-- User joins queue and is auto-filled into the lobby as invited.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_boss_count int;
BEGIN
  SELECT COUNT(*) INTO v_boss_count
  FROM public.raid_bosses
  WHERE id = '00000000-0000-0000-0000-000000000301';

  IF v_boss_count <> 1 THEN
    RAISE EXCEPTION 'Expected authenticated role to read public raid_bosses';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_inactive_raid_count int;
BEGIN
  SELECT COUNT(*) INTO v_inactive_raid_count
  FROM public.raids
  WHERE id = '00000000-0000-0000-0000-000000000402';

  IF v_inactive_raid_count <> 1 THEN
    RAISE EXCEPTION 'Expected queue participant to read their own inactive raid';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_boss_queue('00000000-0000-0000-0000-000000000304', 'smoke-user-join');

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000021'::uuid THEN
    RAISE EXCEPTION 'join_boss_queue returned unexpected user_id';
  END IF;

  IF v_queue.status <> 'invited' THEN
    RAISE EXCEPTION 'join_boss_queue expected status invited, got %', v_queue.status;
  END IF;

  IF v_queue.invited_at IS NULL THEN
    RAISE EXCEPTION 'join_boss_queue expected invited_at to be set for auto-filled join';
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000025', true);

DO $$
DECLARE
  v_left public.raid_queues%ROWTYPE;
  v_promoted public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_left
  FROM public.leave_queue_and_promote('00000000-0000-0000-0000-000000000605', 'Left queue');

  IF v_left.status <> 'left' THEN
    RAISE EXCEPTION 'leave expected left status, got %', v_left.status;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

  SELECT * INTO v_promoted
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-000000000405'
    AND user_id = '00000000-0000-0000-0000-000000000026';

  IF v_promoted.status <> 'invited' THEN
    RAISE EXCEPTION 'leave should promote queued user to invited, got %', v_promoted.status;
  END IF;

  IF v_promoted.invited_at IS NULL THEN
    RAISE EXCEPTION 'leave should set invited_at on promoted user';
  END IF;

  IF v_promoted.position <> 1 THEN
    RAISE EXCEPTION 'leave should renumber promoted user into position 1, got %', v_promoted.position;
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_cancelled public.raid_queues%ROWTYPE;
  v_remaining public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_cancelled
  FROM public.host_update_queue_status(
    '00000000-0000-0000-0000-000000000603',
    'cancelled',
    'smoke-cancel'
  );

  IF v_cancelled.status <> 'cancelled' THEN
    RAISE EXCEPTION 'host_update_queue_status expected cancelled status';
  END IF;

  SELECT * INTO v_remaining
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-000000000404'
    AND user_id = '00000000-0000-0000-0000-000000000024';

  IF v_remaining.status <> 'queued' THEN
    RAISE EXCEPTION 'cancelled should not auto-promote queued rows, got %', v_remaining.status;
  END IF;

  IF v_remaining.position <> 1 THEN
    RAISE EXCEPTION 'cancelled should renumber remaining queued rows to 1, got %', v_remaining.position;
  END IF;

  IF v_remaining.invited_at IS NOT NULL THEN
    RAISE EXCEPTION 'cancelled should not set invited_at on remaining queued rows';
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

-- Idempotency check: second join returns same row for same user+boss.
DO $$
DECLARE
  v_first public.raid_queues%ROWTYPE;
  v_second public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_first
  FROM public.join_boss_queue('00000000-0000-0000-0000-000000000304', NULL);

  SELECT * INTO v_second
  FROM public.join_boss_queue('00000000-0000-0000-0000-000000000304', NULL);

  IF v_first.id <> v_second.id THEN
    RAISE EXCEPTION 'join_boss_queue is not idempotent for same user and boss';
  END IF;

  IF v_second.status <> 'invited' THEN
    RAISE EXCEPTION 'join_boss_queue idempotent return expected invited status, got %', v_second.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Seed a queued row so host_invite_next_in_queue still has a queued candidate to promote.
INSERT INTO public.raid_queues (
  id,
  raid_id,
  user_id,
  status,
  position,
  is_vip,
  note
)
VALUES (
  '00000000-0000-0000-0000-000000000502',
  '00000000-0000-0000-0000-000000000403',
  '00000000-0000-0000-0000-000000000021',
  'queued',
  1,
  false,
  'smoke-queued-host-invite'
)
ON CONFLICT (id) DO NOTHING;

-- Host invites and confirms next queued user from the separately seeded queued raid.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_invited public.raid_queues%ROWTYPE;
  v_confirmed public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_invited
  FROM public.host_invite_next_in_queue('00000000-0000-0000-0000-000000000403');

  IF v_invited.status <> 'invited' THEN
    RAISE EXCEPTION 'host_invite_next_in_queue expected invited status';
  END IF;

  SELECT * INTO v_confirmed
  FROM public.host_update_queue_status(v_invited.id, 'confirmed', 'smoke-confirm');

  IF v_confirmed.status <> 'confirmed' THEN
    RAISE EXCEPTION 'host_update_queue_status expected confirmed status';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Users can insert and read their own activity logs.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

INSERT INTO public.activity_logs (user_id, action, meta)
VALUES (
  '00000000-0000-0000-0000-000000000021',
  'smoke_log_insert',
  '{"source":"sql-test"}'::jsonb
);

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.activity_logs
  WHERE user_id = '00000000-0000-0000-0000-000000000021';

  IF v_count < 1 THEN
    RAISE EXCEPTION 'Expected own activity log row to be visible';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Cross-user visibility should be blocked by RLS.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_cross_count int;
BEGIN
  SELECT COUNT(*) INTO v_cross_count
  FROM public.activity_logs
  WHERE user_id = '00000000-0000-0000-0000-000000000021';

  IF v_cross_count <> 0 THEN
    RAISE EXCEPTION 'RLS leak detected: host can view other user activity logs';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────
-- Phase 3 regression tests: status-predicate enforcement
-- ─────────────────────────────────────────────────────────────

-- Test 1: join_boss_queue with only a 'raiding' raid for boss 302 must NOT join
-- that raid — instead it creates a boss-level queue entry (boss_level_queue
-- migration changed the fallback path from P0002 raise to boss-level insert).
-- The selector still uses status IN ('open','lobby'), so no raid is targeted;
-- the result is a queued boss-level row with raid_id IS NULL.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.join_boss_queue('00000000-0000-0000-0000-000000000302');

  IF v_row.status <> 'queued' THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue expected status=queued boss-level entry, got %', v_row.status;
  END IF;
  IF v_row.raid_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue expected raid_id IS NULL for boss-level entry, got %', v_row.raid_id;
  END IF;
  IF v_row.boss_id <> '00000000-0000-0000-0000-000000000302'::uuid THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue expected boss_id=302, got %', v_row.boss_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 2a: join_boss_queue with only a raiding raid for boss 302 must NOT join
-- it — instead falls back to a boss-level queue entry (raid_id IS NULL, status=queued).
-- Boss 302 fixture only has raid 406 (raiding), so there's no open/lobby slot.
-- Remove the prior boss-level entry from Test 1 first so we exercise the INSERT path.
DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  DELETE FROM public.raid_queues
  WHERE user_id = '00000000-0000-0000-0000-000000000021'
    AND boss_id = '00000000-0000-0000-0000-000000000302'
    AND raid_id IS NULL;

  SELECT * INTO v_row FROM public.join_boss_queue('00000000-0000-0000-0000-000000000302');

  IF v_row.status <> 'queued' OR v_row.raid_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue with only a raiding raid must produce boss-level queued entry, got status=% raid_id=%',
      v_row.status, v_row.raid_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 2b: idempotency on boss-level entry — second call returns the same row.
DO $$
DECLARE
  v_first public.raid_queues%ROWTYPE;
  v_second public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_first  FROM public.join_boss_queue('00000000-0000-0000-0000-000000000302');
  SELECT * INTO v_second FROM public.join_boss_queue('00000000-0000-0000-0000-000000000302');

  IF v_first.id <> v_second.id THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue boss-level entry is not idempotent, got different ids';
  END IF;

  IF v_second.status <> 'queued' OR v_second.raid_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue idempotent boss-level return expected queued+null raid_id, got status=% raid_id=%',
      v_second.status, v_second.raid_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 3a: A user who previously left a raid can re-join it via join_boss_queue.
-- Raid 414 has a pre-seeded 'left' entry for user 22; join_boss_queue routes
-- to raid 414 (sole open boss-304 raid), deletes the terminal row, re-inserts as invited.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000022', true);

DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_boss_queue(
    '00000000-0000-0000-0000-000000000304',
    'smoke-phase3-left-rejoin'
  );

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000022'::uuid THEN
    RAISE EXCEPTION 'Phase 3: left-rejoin returned unexpected user_id';
  END IF;

  IF v_queue.status <> 'invited' THEN
    RAISE EXCEPTION 'Phase 3: left-rejoin expected status invited, got %', v_queue.status;
  END IF;

  IF v_queue.invited_at IS NULL THEN
    RAISE EXCEPTION 'Phase 3: left-rejoin expected invited_at to be set';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 3b: A user whose queue slot was 'cancelled' can also re-join an open raid
-- via join_boss_queue. Raid 414 has a pre-seeded 'cancelled' entry for user 23.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000023', true);

DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_boss_queue(
    '00000000-0000-0000-0000-000000000304',
    'smoke-phase3-cancelled-rejoin'
  );

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000023'::uuid THEN
    RAISE EXCEPTION 'Phase 3: cancelled-rejoin returned unexpected user_id';
  END IF;

  IF v_queue.status <> 'invited' THEN
    RAISE EXCEPTION 'Phase 3: cancelled-rejoin expected status invited, got %', v_queue.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────
-- Phase 2: Raid status lifecycle positive assertions
-- Full arc: open → lobby → raiding → completed
-- Dedicated fixtures: raid 410 (capacity 1), queue entry 690, user 25
-- check_host_inactivity → cancelled: raid 411 (capacity 1), queue 691, user 26
-- ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active
)
VALUES (
  '00000000-0000-0000-0000-000000000410',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Phase2 Lifecycle Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  1,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, last_host_action_at
)
VALUES (
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Phase2 Cancel Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  1,
  true,
  now() - interval '110 seconds'
)
ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000025', true);

INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note, invited_at)
VALUES (
  '00000000-0000-0000-0000-000000000690',
  '00000000-0000-0000-0000-000000000410',
  '00000000-0000-0000-0000-000000000025',
  'invited',
  1,
  false,
  'smoke-phase2-lifecycle',
  now()
)
ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000026', true);

INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note, invited_at)
VALUES (
  '00000000-0000-0000-0000-000000000691',
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000026',
  'confirmed',
  1,
  false,
  'smoke-phase2-cancel',
  now()
)
ON CONFLICT (id) DO NOTHING;

-- Test: newly created raid has status='open'
DO $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM public.raids
  WHERE id = '00000000-0000-0000-0000-000000000410';
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'Phase 2: expected raids.status=open after creation, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: user_confirm_invite → raids.status becomes 'lobby'
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000025', true);
DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
  v_status text;
BEGIN
  SELECT * INTO v_queue FROM public.user_confirm_invite('00000000-0000-0000-0000-000000000690');
  IF v_queue.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Phase 2: user_confirm_invite expected queue.status=confirmed, got %', v_queue.status;
  END IF;
  SELECT status INTO v_status FROM public.raids
  WHERE id = '00000000-0000-0000-0000-000000000410';
  IF v_status <> 'lobby' THEN
    RAISE EXCEPTION 'Phase 2: expected raids.status=lobby after user_confirm_invite, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: start_raid → raids.status becomes 'raiding'
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
DO $$
DECLARE
  v_raid public.raids%ROWTYPE;
BEGIN
  SELECT * INTO v_raid FROM public.start_raid('00000000-0000-0000-0000-000000000410');
  IF v_raid.status <> 'raiding' THEN
    RAISE EXCEPTION 'Phase 2: expected raids.status=raiding after start_raid, got %', v_raid.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: finish_raiding (joiner done) then host_finish_raiding → raids.status becomes 'completed'
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000025', true);
DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue FROM public.finish_raiding('00000000-0000-0000-0000-000000000690');
  IF v_queue.status <> 'done' THEN
    RAISE EXCEPTION 'Phase 2: finish_raiding expected queue.status=done, got %', v_queue.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
DO $$
DECLARE
  v_raid public.raids%ROWTYPE;
BEGIN
  SELECT * INTO v_raid FROM public.host_finish_raiding('00000000-0000-0000-0000-000000000410');
  IF v_raid.status <> 'completed' THEN
    RAISE EXCEPTION 'Phase 2: expected raids.status=completed after host_finish_raiding, got %', v_raid.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: check_host_inactivity → raids.status becomes 'cancelled'
-- Raid 411 has NULL last_host_action_at (triggers inactivity) and a full lobby (1/1).
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
DO $$
DECLARE
  v_result boolean;
  v_status text;
BEGIN
  SELECT * INTO v_result FROM public.check_host_inactivity('00000000-0000-0000-0000-000000000411');
  IF NOT v_result THEN
    RAISE EXCEPTION 'Phase 2: check_host_inactivity expected true (cancellation triggered), got false';
  END IF;
  SELECT status INTO v_status FROM public.raids
  WHERE id = '00000000-0000-0000-0000-000000000411';
  IF v_status <> 'cancelled' THEN
    RAISE EXCEPTION 'Phase 2: expected raids.status=cancelled after check_host_inactivity, got %', v_status;
  END IF;
END;
$$ LANGUAGE plpgsql;


-- Regression: Confirm invite, host read, RLS leak check (Phase 1)
-- Fixture: Insert dedicated raid 412 and queue row 692 for joiner 021
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active
) VALUES (
  '00000000-0000-0000-0000-000000000412',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Regression Test Gym',
  now() + interval '60 minutes',
  now() + interval '120 minutes',
  3,
  true
) ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, invited_at
) VALUES (
  '00000000-0000-0000-0000-000000000692',
  '00000000-0000-0000-0000-000000000412',
  '00000000-0000-0000-0000-000000000021',
  'invited',
  now()
) ON CONFLICT (id) DO NOTHING;

-- 1. As joiner 021, confirm invite
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
DO $$
DECLARE v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.user_confirm_invite('00000000-0000-0000-0000-000000000692');
  IF v_row.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Phase 1: user_confirm_invite expected status=confirmed, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 2. As host 011, can read joiner row as confirmed
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
DO $$
DECLARE v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000692';
  IF v_row.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Phase 1: host read expected status=confirmed, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 3. As third user 022, cannot read joiner row (RLS leak check)
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000022', true);
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000692';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Phase 1: RLS leak, third user can see joiner row';
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────
-- Phase 4: DB-level raid status transition guard — negative tests
-- ─────────────────────────────────────────────────────────────

BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status
)
VALUES
  (
    '00000000-0000-0000-0000-000000000406',
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000301',
    'Phase4 Raiding Fixture',
    now() + interval '30 minutes',
    now() + interval '90 minutes',
    3,
    true,
    'raiding'
  ),
  (
    '00000000-0000-0000-0000-000000000407',
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000301',
    'Phase4 Completed Fixture',
    now() - interval '90 minutes',
    now() - interval '30 minutes',
    3,
    true,
    'completed'
  ),
  (
    '00000000-0000-0000-0000-000000000408',
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000301',
    'Phase4 Cancelled Fixture',
    now() - interval '90 minutes',
    now() - interval '30 minutes',
    3,
    true,
    'cancelled'
  ),
  (
    '00000000-0000-0000-0000-000000000409',
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000301',
    'Phase4 Open Fixture',
    now() + interval '30 minutes',
    now() + interval '90 minutes',
    3,
    true,
    'open'
  )
ON CONFLICT (id) DO UPDATE
SET status = EXCLUDED.status,
    is_active = EXCLUDED.is_active;

-- Test: completed → open (should fail)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.raids SET status = 'open' WHERE id = '00000000-0000-0000-0000-000000000407';
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Phase 4: completed → open should be blocked by status transition guard';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: cancelled → open (should fail)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.raids SET status = 'open' WHERE id = '00000000-0000-0000-0000-000000000408';
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Phase 4: cancelled → open should be blocked by status transition guard';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: raiding → open (should fail)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.raids SET status = 'open' WHERE id = '00000000-0000-0000-0000-000000000406';
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Phase 4: raiding → open should be blocked by status transition guard';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: open → raiding (should fail — intentionally absent direct path)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.raids SET status = 'raiding' WHERE id = '00000000-0000-0000-0000-000000000409';
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Phase 4: open → raiding should be blocked by status transition guard';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test: open → completed (should fail)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.raids SET status = 'completed' WHERE id = '00000000-0000-0000-0000-000000000409';
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Phase 4: open → completed should be blocked by status transition guard';
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────
-- Realtime feature: claim_realtime_slot, release_realtime_slot,
-- admin_update_realtime_slots guard, get_realtime_slot_stats
-- ─────────────────────────────────────────────────────────────

BEGIN;

-- realtime_sessions.user_id has FK → auth.users(id).
-- Seed user 021 so claim_realtime_slot can insert without FK violation.
INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES (
  '00000000-0000-0000-0000-000000000021',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  'smoke-user-021@raidsync.local',
  '', now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  false, false
) ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;

-- Test R1: claim_realtime_slot() → granted=true, mode='realtime'
-- User 021 is non-VIP; active session count starts at 0 (< default 150 slots).
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT public.claim_realtime_slot() INTO v_result;
  IF NOT (v_result->>'granted')::boolean THEN
    RAISE EXCEPTION 'Realtime R1: claim_realtime_slot expected granted=true, got %', v_result;
  END IF;
  IF v_result->>'mode' <> 'realtime' THEN
    RAISE EXCEPTION 'Realtime R1: claim_realtime_slot expected mode=realtime, got %', v_result->>'mode';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test R2: release_realtime_slot() → session row removed for caller.
-- Depends on R1 having written a session row for user 021.
DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM public.release_realtime_slot();
  SELECT COUNT(*) INTO v_count
  FROM public.realtime_sessions
  WHERE user_id = '00000000-0000-0000-0000-000000000021';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Realtime R2: release_realtime_slot expected 0 rows after release, found %', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test R4: get_realtime_slot_stats() → used >= 0, total = 150 (default).
-- Runs after R2 (release), so this user holds no session; used reflects other rows.
DO $$
DECLARE
  v_stats jsonb;
BEGIN
  SELECT public.get_realtime_slot_stats() INTO v_stats;
  IF (v_stats->>'used')::int < 0 THEN
    RAISE EXCEPTION 'Realtime R4: used must be >= 0, got %', v_stats->>'used';
  END IF;
  IF (v_stats->>'total') IS NULL OR (v_stats->>'total')::int <> 150 THEN
    RAISE EXCEPTION 'Realtime R4: total must = 150 (default realtime_slots), got %', v_stats->>'total';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test R3: admin_update_realtime_slots() → raises Unauthorized for non-admin caller.
-- User 021 has no user_profiles row with is_admin=true (column defaults false).
-- The function must raise EXCEPTION 'Unauthorized' before touching app_config.
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_update_realtime_slots(5);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Unauthorized%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'Realtime R3: admin_update_realtime_slots must raise Unauthorized for non-admin user';
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;

-- ============================================================
-- Session Audit Trail Tests
-- Users: A = 00000000-0000-0000-0000-000000000021
--        B = 00000000-0000-0000-0000-000000000022
-- ============================================================

BEGIN;

SET LOCAL ROLE authenticated;

-- Test SA-1: open_user_session returns a UUID when called as user A
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_session_id uuid;
BEGIN
  SELECT public.open_user_session(
    'Mozilla/5.0 (smoke test)',
    '{"tab_id":"sa-test","screen_w":1920,"screen_h":1080}'::jsonb
  ) INTO v_session_id;

  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'SA-1: open_user_session returned NULL';
  END IF;

  -- Store session_id for use in subsequent tests within this transaction
  PERFORM set_config('sa.session_id_a', v_session_id::text, true);
END;
$$ LANGUAGE plpgsql;

-- Test SA-2: user A can SELECT their own user_sessions row (RLS positive)
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.user_sessions
  WHERE id = current_setting('sa.session_id_a')::uuid;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'SA-2: user A should see own session row, count=%', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-3: user B cannot SELECT user A's user_sessions row (RLS negative)
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000022', true);

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.user_sessions
  WHERE id = current_setting('sa.session_id_a')::uuid;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'SA-3: RLS leak — user B can see user A session, count=%', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-4: batch_insert_session_events inserts events for owned session
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_session_id uuid;
  v_count int;
BEGIN
  v_session_id := current_setting('sa.session_id_a')::uuid;

  PERFORM public.batch_insert_session_events(
    v_session_id,
    '[
      {"seq":1,"event_type":"session","event_name":"session.opened","payload":{}},
      {"seq":2,"event_type":"nav","event_name":"nav.view_switch","payload":{"view":"queues"}}
    ]'::jsonb
  );

  SELECT COUNT(*) INTO v_count
  FROM public.session_events
  WHERE session_id = v_session_id;

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'SA-4: expected 2 events inserted, got %', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-5: batch_insert_session_events raises on wrong session_id (other user's session)
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000022', true);

DO $$
DECLARE
  v_session_id uuid;
  v_caught boolean := false;
BEGIN
  v_session_id := current_setting('sa.session_id_a')::uuid;

  BEGIN
    PERFORM public.batch_insert_session_events(
      v_session_id,
      '[{"seq":99,"event_type":"nav","event_name":"nav.view_switch","payload":{}}]'::jsonb
    );
  EXCEPTION
    WHEN SQLSTATE '42501' THEN
      v_caught := true;
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%access denied%' OR SQLERRM LIKE '%not found%' THEN
        v_caught := true;
      END IF;
  END;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-5: batch_insert_session_events should reject cross-user session_id';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-6: close_user_session sets ended_at + end_reason
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_session_id uuid;
  v_row public.user_sessions%ROWTYPE;
BEGIN
  v_session_id := current_setting('sa.session_id_a')::uuid;

  PERFORM public.close_user_session(v_session_id, 'sign_out', '[]'::jsonb);

  SELECT * INTO v_row FROM public.user_sessions WHERE id = v_session_id;

  IF v_row.ended_at IS NULL THEN
    RAISE EXCEPTION 'SA-6: close_user_session did not set ended_at';
  END IF;
  IF v_row.end_reason <> 'sign_out' THEN
    RAISE EXCEPTION 'SA-6: close_user_session expected end_reason=sign_out, got %', v_row.end_reason;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-7: close_user_session with p_final_events flushes remaining buffer
-- Opens a fresh session so ended_at IS NULL guard is valid.
DO $$
DECLARE
  v_session_id uuid;
  v_count int;
BEGIN
  SELECT public.open_user_session('smoke-final-flush', '{}'::jsonb) INTO v_session_id;

  PERFORM public.close_user_session(
    v_session_id,
    'page_close',
    '[{"seq":1,"event_type":"session","event_name":"session.closed","payload":{}}]'::jsonb
  );

  SELECT COUNT(*) INTO v_count
  FROM public.session_events
  WHERE session_id = v_session_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'SA-7: expected 1 final event flushed by close_user_session, got %', v_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-8: user cannot DELETE session_events rows (no DELETE policy)
-- RLS with no DELETE policy silently returns 0 rows deleted — no error raised.
DO $$
DECLARE
  v_session_id  uuid;
  v_rows_before int;
  v_rows_after  int;
BEGIN
  SELECT public.open_user_session('smoke-delete-test', '{}'::jsonb) INTO v_session_id;

  PERFORM public.batch_insert_session_events(
    v_session_id,
    '[{"seq":1,"event_type":"nav","event_name":"nav.view_switch","payload":{}}]'::jsonb
  );

  SELECT COUNT(*) INTO v_rows_before FROM public.session_events WHERE session_id = v_session_id;

  -- Direct DELETE: no DELETE policy exists, so 0 rows are deleted (RLS default deny)
  DELETE FROM public.session_events WHERE session_id = v_session_id;

  SELECT COUNT(*) INTO v_rows_after FROM public.session_events WHERE session_id = v_session_id;

  IF v_rows_after <> v_rows_before THEN
    RAISE EXCEPTION 'SA-8: RLS DELETE leak — rows before=%, after=% (DELETE should be blocked)', v_rows_before, v_rows_after;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-9: get_session_replay returns correct shape (session + profile + events + state_transitions)
DO $$
DECLARE
  v_session_id uuid;
  v_replay jsonb;
BEGIN
  SELECT public.open_user_session('smoke-replay-test', '{}'::jsonb) INTO v_session_id;

  PERFORM public.batch_insert_session_events(
    v_session_id,
    '[{"seq":1,"event_type":"nav","event_name":"nav.view_switch","payload":{"view":"home"}}]'::jsonb
  );

  SELECT public.get_session_replay(v_session_id) INTO v_replay;

  IF v_replay IS NULL THEN
    RAISE EXCEPTION 'SA-9: get_session_replay returned NULL';
  END IF;
  IF v_replay->>'session' IS NULL THEN
    RAISE EXCEPTION 'SA-9: get_session_replay missing session key';
  END IF;
  IF v_replay->'events' IS NULL THEN
    RAISE EXCEPTION 'SA-9: get_session_replay missing events key';
  END IF;
  IF jsonb_array_length(v_replay->'events') <> 1 THEN
    RAISE EXCEPTION 'SA-9: expected 1 event in replay, got %', jsonb_array_length(v_replay->'events');
  END IF;
  IF v_replay->'state_transitions' IS NULL THEN
    RAISE EXCEPTION 'SA-9: get_session_replay missing state_transitions key';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-10: UNIQUE(session_id, seq) — duplicate seq ON CONFLICT DO NOTHING (idempotent flush)
DO $$
DECLARE
  v_session_id   uuid;
  v_count_before int;
  v_count_after  int;
BEGIN
  SELECT public.open_user_session('smoke-idempotent', '{}'::jsonb) INTO v_session_id;

  -- First insert: seq=1
  PERFORM public.batch_insert_session_events(
    v_session_id,
    '[{"seq":1,"event_type":"nav","event_name":"nav.view_switch","payload":{}}]'::jsonb
  );

  SELECT COUNT(*) INTO v_count_before FROM public.session_events WHERE session_id = v_session_id;

  -- Duplicate seq=1: should be silently ignored via ON CONFLICT DO NOTHING
  PERFORM public.batch_insert_session_events(
    v_session_id,
    '[{"seq":1,"event_type":"nav","event_name":"nav.view_switch","payload":{}}]'::jsonb
  );

  SELECT COUNT(*) INTO v_count_after FROM public.session_events WHERE session_id = v_session_id;

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'SA-10: idempotent flush failed — before=%, after=% (duplicate seq must be skipped)', v_count_before, v_count_after;
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────
-- SA-11: admin_update_audit_config — admin guard + success path
-- ─────────────────────────────────────────────────────────────

BEGIN;

-- Fixture: seed auth.users row for user 011 (admin) and user 021 (non-admin)
-- so user_profiles FK and admin check work.
INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES
  (
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-host-011@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  ),
  (
    '00000000-0000-0000-0000-000000000021',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-user-021@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  )
ON CONFLICT (id) DO NOTHING;

-- Seed user_profiles: user 011 = admin, user 021 = non-admin
INSERT INTO public.user_profiles (auth_id, is_admin)
VALUES
  ('00000000-0000-0000-0000-000000000011', true),
  ('00000000-0000-0000-0000-000000000021', false)
ON CONFLICT (auth_id) DO UPDATE SET is_admin = EXCLUDED.is_admin;

SET LOCAL ROLE authenticated;

-- Test SA-11a: non-admin calling admin_update_audit_config raises Unauthorized
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_update_audit_config('{
      "enabled": true,
      "categories": { "session": true, "error": true }
    }'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%Unauthorized%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-11a: admin_update_audit_config must raise Unauthorized for non-admin user';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-11b: admin calling admin_update_audit_config succeeds and column updates
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_config jsonb;
BEGIN
  PERFORM public.admin_update_audit_config('{
    "enabled": false,
    "flush_interval_ms": 10000,
    "buffer_max": 100,
    "categories": {
      "session": true,
      "error": true,
      "nav": true,
      "queue": false,
      "host": false,
      "lifecycle": false,
      "realtime": false,
      "data": false,
      "account": false,
      "admin": false
    }
  }'::jsonb);

  SELECT audit_config INTO v_config FROM public.app_config WHERE id = 1;

  IF v_config IS NULL THEN
    RAISE EXCEPTION 'SA-11b: audit_config is NULL after admin update';
  END IF;
  IF (v_config->>'enabled')::boolean <> false THEN
    RAISE EXCEPTION 'SA-11b: expected enabled=false, got %', v_config->>'enabled';
  END IF;
  IF (v_config->>'flush_interval_ms')::int <> 10000 THEN
    RAISE EXCEPTION 'SA-11b: expected flush_interval_ms=10000, got %', v_config->>'flush_interval_ms';
  END IF;
  IF (v_config->'categories'->>'nav')::boolean <> true THEN
    RAISE EXCEPTION 'SA-11b: expected categories.nav=true, got %', v_config->'categories'->>'nav';
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;


-- SA-12: admin_purge_audit_trail � admin guard + success path
-- -------------------------------------------------------------

BEGIN;

-- Fixture: seed auth.users row for user 011 (admin) and user 021 (non-admin).
-- SA-11 seeds and rolls back these rows, so SA-12 must re-seed them.
INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES
  (
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-host-011@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  ),
  (
    '00000000-0000-0000-0000-000000000021',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-user-021@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  )
ON CONFLICT (id) DO NOTHING;

-- Seed user_profiles: user 011 = admin, user 021 = non-admin
INSERT INTO public.user_profiles (auth_id, is_admin)
VALUES
  ('00000000-0000-0000-0000-000000000011', true),
  ('00000000-0000-0000-0000-000000000021', false)
ON CONFLICT (auth_id) DO UPDATE SET is_admin = EXCLUDED.is_admin;

SET LOCAL ROLE authenticated;

-- Test SA-12a: non-admin calling admin_purge_audit_trail raises Unauthorized
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_purge_audit_trail('anyone@example.com');
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-12a: admin_purge_audit_trail must raise 42501 for non-admin user';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-12b: admin calling with a nonexistent email raises "User not found"
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_purge_audit_trail('nonexistent@raidsync.local');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%User not found%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-12b: admin_purge_audit_trail must raise "User not found" for unknown email';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test SA-12c: admin calling admin_purge_audit_trail(NULL) succeeds (purge all)
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT public.admin_purge_audit_trail(NULL) INTO v_result;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'SA-12c: admin_purge_audit_trail(NULL) returned NULL';
  END IF;
  IF v_result->>'target' <> 'ALL' THEN
    RAISE EXCEPTION 'SA-12c: expected target=ALL, got %', v_result->>'target';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'SA-12: admin_purge_audit_trail � all assertions passed'; END; $$;

ROLLBACK;

-- ============================================================
-- invite_attempts smoke tests
-- ============================================================

-- Test IA-1: Expire → tail (joined_at = now()) → auto-promote next queued user
BEGIN;

-- Fixture: boss, raid (open, capacity 5), auth.users for host + 2 joiners
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES
  (
    '00000000-0000-0000-0000-000000000011',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-host-011@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  ),
  (
    '00000000-0000-0000-0000-000000000021',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-user-021@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  ),
  (
    '00000000-0000-0000-0000-000000000022',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'smoke-user-022@raidsync.local',
    '', now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false, false
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status
) VALUES (
  '00000000-0000-0000-0000-000000000801',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'IA Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  5, true, 'open'
) ON CONFLICT (id) DO NOTHING;

-- User 21 is invited with expired timer
INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
) VALUES (
  '00000000-0000-0000-0000-000000000901',
  '00000000-0000-0000-0000-000000000801',
  '00000000-0000-0000-0000-000000000021',
  'invited', 1, false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  0
) ON CONFLICT (id) DO NOTHING;

-- User 22 is next in queue
INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
) VALUES (
  '00000000-0000-0000-0000-000000000912',
  '00000000-0000-0000-0000-000000000801',
  '00000000-0000-0000-0000-000000000022',
  'queued', 2, false,
  NULL,
  now() - interval '4 minutes',
  0
) ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count int;
  v_expired public.raid_queues%ROWTYPE;
  v_promoted public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000801') INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'IA-1: expected 1 processed, got %', v_count;
  END IF;

  -- Expired user should be queued at tail (joined_at reset to now())
  SELECT * INTO v_expired FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000901';
  IF v_expired.status <> 'queued' THEN
    RAISE EXCEPTION 'IA-1: expired user expected status=queued, got %', v_expired.status;
  END IF;
  IF v_expired.invited_at IS NOT NULL THEN
    RAISE EXCEPTION 'IA-1: expired user invited_at should be NULL';
  END IF;
  -- joined_at should have been reset to now() (tail penalty)
  IF v_expired.joined_at < now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'IA-1: expired user joined_at not reset to now() — tail penalty missing';
  END IF;

  -- Next queued user should be auto-promoted to invited
  SELECT * INTO v_promoted FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000912';
  IF v_promoted.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-1: next queued user expected status=invited (auto-promote), got %', v_promoted.status;
  END IF;
  IF v_promoted.invited_at IS NULL THEN
    RAISE EXCEPTION 'IA-1: promoted user invited_at should not be NULL';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-1: expire to tail + auto-promote next — PASSED'; END; $$;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────
-- expired_joiner_fallback
-- ─────────────────────────────────────────────────────────────
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-00000000f001', 'Fallback Boss', 5, 901)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id,
  host_user_id,
  raid_boss_id,
  location_name,
  start_time,
  end_time,
  capacity,
  is_active,
  status
)
VALUES (
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f011',
  '00000000-0000-0000-0000-00000000f001',
  'Fallback Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  2,
  true,
  'open'
)
ON CONFLICT (id) DO NOTHING;

-- 1. Sole expired entry, no fresh candidates: should be re-invited
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';
UPDATE public.raids
SET status = 'open', capacity = 2
WHERE id = '00000000-0000-0000-0000-00000000f100';

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f201',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f021',
  'invited',
  1,
  false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  4
);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_row
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: sole expired entry should be re-invited, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 2. Repeated expire cycle: should be re-invited again
UPDATE public.raid_queues
SET invited_at = now() - interval '90 seconds'
WHERE id = '00000000-0000-0000-0000-00000000f201';

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_row
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: repeated expire should re-invite, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 3. Multiple expired entries, one VIP: VIP should be re-invited
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES
  (
    '00000000-0000-0000-0000-00000000f201',
    '00000000-0000-0000-0000-00000000f100',
    '00000000-0000-0000-0000-00000000f021',
    'invited',
    1,
    false,
    now() - interval '90 seconds',
    now() - interval '5 minutes',
    1
  ),
  (
    '00000000-0000-0000-0000-00000000f202',
    '00000000-0000-0000-0000-00000000f100',
    '00000000-0000-0000-0000-00000000f022',
    'invited',
    2,
    true,
    now() - interval '90 seconds',
    now() - interval '4 minutes',
    2
  );

DO $$
DECLARE
  v_invited_id uuid;
  v_remaining_status text;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT id INTO v_invited_id
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
    AND status = 'invited';

  SELECT status INTO v_remaining_status
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_invited_id <> '00000000-0000-0000-0000-00000000f202'::uuid THEN
    RAISE EXCEPTION 'expired_joiner_fallback: VIP should be re-invited, got %', v_invited_id;
  END IF;

  IF v_remaining_status <> 'queued' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: non-VIP expired entry should remain queued, got %', v_remaining_status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 4. Fresh queued candidate wins over expired
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES
  (
    '00000000-0000-0000-0000-00000000f201',
    '00000000-0000-0000-0000-00000000f100',
    '00000000-0000-0000-0000-00000000f021',
    'invited',
    1,
    false,
    now() - interval '90 seconds',
    now() - interval '5 minutes',
    1
  ),
  (
    '00000000-0000-0000-0000-00000000f202',
    '00000000-0000-0000-0000-00000000f100',
    '00000000-0000-0000-0000-00000000f022',
    'invited',
    2,
    true,
    now() - interval '90 seconds',
    now() - interval '4 minutes',
    2
  ),
  (
    '00000000-0000-0000-0000-00000000f203',
    '00000000-0000-0000-0000-00000000f100',
    '00000000-0000-0000-0000-00000000f023',
    'queued',
    3,
    false,
    NULL,
    now() - interval '1 minute',
    0
  );

DO $$
DECLARE
  v_invited_id uuid;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT id INTO v_invited_id
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
    AND status = 'invited';

  IF v_invited_id <> '00000000-0000-0000-0000-00000000f203'::uuid THEN
    RAISE EXCEPTION 'expired_joiner_fallback: fresh queued should win, got %', v_invited_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5. Boss-queue candidate wins over expired
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f201',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f021',
  'invited',
  1,
  false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  1
);

INSERT INTO public.raid_queues (
  id, raid_id, boss_id, user_id, status, is_vip, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f301',
  NULL,
  '00000000-0000-0000-0000-00000000f001',
  '00000000-0000-0000-0000-00000000f024',
  'queued',
  false,
  now() - interval '6 minutes',
  0
);

DO $$
DECLARE
  v_boss public.raid_queues%ROWTYPE;
  v_expired public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_boss
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f301';

  SELECT * INTO v_expired
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_boss.status <> 'invited' OR v_boss.raid_id <> '00000000-0000-0000-0000-00000000f100'::uuid THEN
    RAISE EXCEPTION 'expired_joiner_fallback: boss-level queued candidate should be promoted, got status=% raid_id=%',
      v_boss.status, v_boss.raid_id;
  END IF;

  IF v_expired.status <> 'queued' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: expired raid-level entry should stay queued after Step B, got %', v_expired.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 6. Raid full skips fallback
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';
UPDATE public.raids
SET status = 'open', capacity = 1
WHERE id = '00000000-0000-0000-0000-00000000f100';

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f201',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f021',
  'invited',
  1,
  false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  1
);

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f204',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f025',
  'confirmed',
  2,
  false,
  now() - interval '10 minutes',
  0
);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_row
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_row.status <> 'queued' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: raid full should leave expired entry queued, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 7. Non-open/lobby raid skips fallback
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';
DELETE FROM public.raids WHERE id = '00000000-0000-0000-0000-00000000f100';
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status
) VALUES (
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f011',
  '00000000-0000-0000-0000-00000000f001',
  'Fallback Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  2,
  false,
  'cancelled'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f201',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f021',
  'invited',
  1,
  false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  1
);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_row
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  IF v_row.status <> 'queued' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: non-open/lobby should leave expired entry queued, got %', v_row.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 8. Regression: Step B promotion prevents Step C
DELETE FROM public.raid_queues
WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
   OR boss_id = '00000000-0000-0000-0000-00000000f001';
DELETE FROM public.raids WHERE id = '00000000-0000-0000-0000-00000000f100';
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status
) VALUES (
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f011',
  '00000000-0000-0000-0000-00000000f001',
  'Fallback Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  2,
  true,
  'open'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (
  id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f201',
  '00000000-0000-0000-0000-00000000f100',
  '00000000-0000-0000-0000-00000000f021',
  'invited',
  1,
  false,
  now() - interval '90 seconds',
  now() - interval '5 minutes',
  1
);

INSERT INTO public.raid_queues (
  id, raid_id, boss_id, user_id, status, is_vip, joined_at, invite_attempts
)
VALUES (
  '00000000-0000-0000-0000-00000000f302',
  NULL,
  '00000000-0000-0000-0000-00000000f001',
  '00000000-0000-0000-0000-00000000f026',
  'queued',
  false,
  now() - interval '6 minutes',
  0
);

DO $$
DECLARE
  v_boss public.raid_queues%ROWTYPE;
  v_expired public.raid_queues%ROWTYPE;
  v_invited_count int;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-00000000f100');

  SELECT * INTO v_boss
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f302';

  SELECT * INTO v_expired
  FROM public.raid_queues
  WHERE id = '00000000-0000-0000-0000-00000000f201';

  SELECT COUNT(*) INTO v_invited_count
  FROM public.raid_queues
  WHERE raid_id = '00000000-0000-0000-0000-00000000f100'
    AND status = 'invited';

  IF v_boss.status <> 'invited' OR v_boss.raid_id <> '00000000-0000-0000-0000-00000000f100'::uuid THEN
    RAISE EXCEPTION 'expired_joiner_fallback: regression expected Step B candidate to be invited, got status=% raid_id=%',
      v_boss.status, v_boss.raid_id;
  END IF;

  IF v_expired.status <> 'queued' THEN
    RAISE EXCEPTION 'expired_joiner_fallback: regression expected expired raid-level entry to stay queued, got %', v_expired.status;
  END IF;

  IF v_invited_count <> 1 THEN
    RAISE EXCEPTION 'expired_joiner_fallback: regression expected exactly one invited row after Step B, got %', v_invited_count;
  END IF;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;

-- Test IA-1b: Solo user expires — should be re-invited when no fresh candidates remain
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000810', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-1b Solo Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- Only user in queue, invited and expired
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000915', '00000000-0000-0000-0000-000000000810', '00000000-0000-0000-0000-000000000021', 'invited', 1, false, now() - interval '90 seconds', now() - interval '5 minutes', 0)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count int;
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000810') INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'IA-1b: expected 1 processed, got %', v_count;
  END IF;

  SELECT * INTO v_row FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000915';
  -- With sole-candidate fallback, the same user is re-invited.
  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-1b: solo user expected status=invited, got %', v_row.status;
  END IF;
  IF v_row.invited_at IS NULL THEN
    RAISE EXCEPTION 'IA-1b: solo user invited_at should be reset after re-invite';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-1b: solo user expire — sole-candidate re-invite — PASSED'; END; $$;

ROLLBACK;

-- Test IA-2: user_confirm_invite resets invite_attempts to 0
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-2 Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000902', '00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000021', 'invited', 1, false, now(), now() - interval '5 minutes', 2)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.user_confirm_invite('00000000-0000-0000-0000-000000000902');
  IF v_row.status <> 'confirmed' THEN
    RAISE EXCEPTION 'IA-2: expected status=confirmed, got %', v_row.status;
  END IF;
  IF v_row.invite_attempts <> 0 THEN
    RAISE EXCEPTION 'IA-2: expected invite_attempts=0 after confirm, got %', v_row.invite_attempts;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-2: confirm resets counter — PASSED'; END; $$;

ROLLBACK;

-- Test IA-3: host_invite_next_in_queue resets invite_attempts to 0
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000803', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-3 Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- User is queued with invite_attempts=3 (simulates cap-hit requeue)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000903', '00000000-0000-0000-0000-000000000803', '00000000-0000-0000-0000-000000000021', 'queued', 1, false, NULL, now() - interval '5 minutes', 3)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.host_invite_next_in_queue('00000000-0000-0000-0000-000000000803');
  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-3: expected status=invited, got %', v_row.status;
  END IF;
  IF v_row.invite_attempts <> 0 THEN
    RAISE EXCEPTION 'IA-3: expected invite_attempts=0 after host invite, got %', v_row.invite_attempts;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-3: host invite resets counter — PASSED'; END; $$;

ROLLBACK;

-- Test IA-4: promote_next_queued_user resets invite_attempts to 0
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000804', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-4 Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- User is queued with invite_attempts=3 (capped)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000904', '00000000-0000-0000-0000-000000000804', '00000000-0000-0000-0000-000000000021', 'queued', 1, false, NULL, now() - interval '5 minutes', 3)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_row public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.promote_next_queued_user('00000000-0000-0000-0000-000000000804');

  SELECT * INTO v_row FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000904';
  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-4: expected status=invited after promote, got %', v_row.status;
  END IF;
  IF v_row.invite_attempts <> 0 THEN
    RAISE EXCEPTION 'IA-4: expected invite_attempts=0 after promote, got %', v_row.invite_attempts;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-4: promote resets counter — PASSED'; END; $$;

ROLLBACK;

-- Test IA-5: Raid full (confirmed = capacity) → expired entry reverts to queued
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-022@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

-- Raid with capacity=1
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000805', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-5 Full Gym', now() + interval '30 minutes', now() + interval '90 minutes', 1, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- One confirmed user fills capacity
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000905', '00000000-0000-0000-0000-000000000805', '00000000-0000-0000-0000-000000000022', 'confirmed', 1, false, now() - interval '2 minutes', now() - interval '10 minutes', 0)
ON CONFLICT (id) DO NOTHING;

-- Expired invited user at invite_attempts=0
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000906', '00000000-0000-0000-0000-000000000805', '00000000-0000-0000-0000-000000000021', 'invited', 2, false, now() - interval '90 seconds', now() - interval '5 minutes', 0)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count int;
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000805') INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'IA-5: expected 1 processed, got %', v_count;
  END IF;

  SELECT * INTO v_row FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000906';
  IF v_row.status <> 'queued' THEN
    RAISE EXCEPTION 'IA-5: expected status=queued (raid full), got %', v_row.status;
  END IF;
  -- joined_at should be reset to now() (tail penalty)
  IF v_row.joined_at < now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'IA-5: joined_at not reset — tail penalty missing';
  END IF;
  -- No auto-promote should happen since raid is full
  IF EXISTS (SELECT 1 FROM public.raid_queues WHERE raid_id = '00000000-0000-0000-0000-000000000805' AND status = 'invited') THEN
    RAISE EXCEPTION 'IA-5: should not auto-promote when raid is full';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-5: raid full revert — PASSED'; END; $$;

ROLLBACK;

-- Test IA-6: Raid closed (status not in open/lobby) → expired entry reverts to queued
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

-- Raid with status='raiding' (not open/lobby)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000806', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-6 Closed Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'raiding')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000907', '00000000-0000-0000-0000-000000000806', '00000000-0000-0000-0000-000000000021', 'invited', 1, false, now() - interval '90 seconds', now() - interval '5 minutes', 0)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count int;
  v_row public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000806') INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'IA-6: expected 1 processed, got %', v_count;
  END IF;

  SELECT * INTO v_row FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000907';
  IF v_row.status <> 'queued' THEN
    RAISE EXCEPTION 'IA-6: expected status=queued (raid closed), got %', v_row.status;
  END IF;
  -- joined_at should be reset to now() (tail penalty)
  IF v_row.joined_at < now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'IA-6: joined_at not reset — tail penalty missing';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-6: raid closed revert — PASSED'; END; $$;

ROLLBACK;

-- Test IA-7: Multiple simultaneous expires — all revert to tail, one auto-promoted
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-022@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-023@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000807', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-7 Multi Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- User 21: expired invited
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000908', '00000000-0000-0000-0000-000000000807', '00000000-0000-0000-0000-000000000021', 'invited', 1, false, now() - interval '90 seconds', now() - interval '10 minutes', 0)
ON CONFLICT (id) DO NOTHING;

-- User 22: expired invited
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000909', '00000000-0000-0000-0000-000000000807', '00000000-0000-0000-0000-000000000022', 'invited', 2, false, now() - interval '90 seconds', now() - interval '8 minutes', 0)
ON CONFLICT (id) DO NOTHING;

-- User 23: next in queue (should get auto-promoted)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000913', '00000000-0000-0000-0000-000000000807', '00000000-0000-0000-0000-000000000023', 'queued', 3, false, NULL, now() - interval '6 minutes', 0)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count int;
  v_row21 public.raid_queues%ROWTYPE;
  v_row22 public.raid_queues%ROWTYPE;
  v_row23 public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000807') INTO v_count;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'IA-7: expected 2 processed, got %', v_count;
  END IF;

  -- Both expired users should be queued at tail
  SELECT * INTO v_row21 FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000908';
  IF v_row21.status <> 'queued' THEN
    RAISE EXCEPTION 'IA-7: user 21 expected status=queued, got %', v_row21.status;
  END IF;
  IF v_row21.joined_at < now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'IA-7: user 21 joined_at not reset to now()';
  END IF;

  SELECT * INTO v_row22 FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000909';
  IF v_row22.status <> 'queued' THEN
    RAISE EXCEPTION 'IA-7: user 22 expected status=queued, got %', v_row22.status;
  END IF;
  IF v_row22.joined_at < now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'IA-7: user 22 joined_at not reset to now()';
  END IF;

  -- User 23 should be auto-promoted to invited
  SELECT * INTO v_row23 FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000913';
  IF v_row23.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-7: user 23 expected status=invited (auto-promote), got %', v_row23.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-7: multiple simultaneous expires + auto-promote — PASSED'; END; $$;

ROLLBACK;

-- Test IA-8: One-invite guard survives after auto-promote
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-022@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-023@raidsync.local', '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, start_time, end_time, capacity, is_active, status)
VALUES ('00000000-0000-0000-0000-000000000808', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000301', 'IA-8 Guard Gym', now() + interval '30 minutes', now() + interval '90 minutes', 5, true, 'open')
ON CONFLICT (id) DO NOTHING;

-- User 21 is invited with expired timer
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000910', '00000000-0000-0000-0000-000000000808', '00000000-0000-0000-0000-000000000021', 'invited', 1, false, now() - interval '90 seconds', now() - interval '10 minutes', 0)
ON CONFLICT (id) DO NOTHING;

-- User 22 is next in queue (will be auto-promoted)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000911', '00000000-0000-0000-0000-000000000808', '00000000-0000-0000-0000-000000000022', 'queued', 2, false, NULL, now() - interval '8 minutes', 0)
ON CONFLICT (id) DO NOTHING;

-- User 23 is also queued
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES ('00000000-0000-0000-0000-000000000914', '00000000-0000-0000-0000-000000000808', '00000000-0000-0000-0000-000000000023', 'queued', 3, false, NULL, now() - interval '6 minutes', 0)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

-- Expire triggers auto-promote of user 22
DO $$
DECLARE
  v_row22 public.raid_queues%ROWTYPE;
BEGIN
  PERFORM public.expire_stale_invites('00000000-0000-0000-0000-000000000808');

  -- User 22 should now be invited (auto-promoted)
  SELECT * INTO v_row22 FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000911';
  IF v_row22.status <> 'invited' THEN
    RAISE EXCEPTION 'IA-8 setup: user 22 should be auto-promoted to invited, got %', v_row22.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- host_invite_next_in_queue should reject because user 22 is now invited (via auto-promote)
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.host_invite_next_in_queue('00000000-0000-0000-0000-000000000808');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%already invited%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'IA-8: host_invite_next_in_queue should reject — one-invite guard violated';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'IA-8: one-invite guard survives after auto-promote — PASSED'; END; $$;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────
-- SC tests: status_changed_at heartbeat immunity + raidsVersion
-- ─────────────────────────────────────────────────────────────

BEGIN;

-- SC test fixture (self-contained — data does not persist between test suites)
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000301',
  'Test Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  3,
  true,
  'open'
)
ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

-- ============================================================
-- SC-1: raidsVersion present and non-null when non-terminal raid exists
-- ============================================================
DO $$
DECLARE v_result jsonb;
BEGIN
  SELECT public.get_queue_sync_state(NULL) INTO v_result;
  IF v_result->>'raidsVersion' IS NULL THEN
    RAISE EXCEPTION 'SC-1: raidsVersion must be non-null when an active raid exists';
  END IF;
END; $$ LANGUAGE plpgsql;
DO $$ BEGIN RAISE NOTICE 'SC-1: raidsVersion present — PASSED'; END; $$;

-- ============================================================
-- SC-2: touch_host_activity (heartbeat) does NOT bump raidsVersion
-- ============================================================
DO $$
DECLARE
  v_before  jsonb;
  v_after   jsonb;
  v_touched integer;
BEGIN
  SELECT public.get_queue_sync_state(NULL) INTO v_before;
  UPDATE public.raids
    SET last_host_action_at = now()
    WHERE id = '00000000-0000-0000-0000-000000000401'
      AND host_user_id = '00000000-0000-0000-0000-000000000011'
      AND is_active = true;
  GET DIAGNOSTICS v_touched = ROW_COUNT;
  IF v_touched = 0 THEN
    RAISE EXCEPTION 'SC-2: touch_host_activity precondition failed — 0 rows updated; test fixture may be wrong';
  END IF;
  SELECT public.get_queue_sync_state(NULL) INTO v_after;
  IF (v_before->>'raidsVersion') IS DISTINCT FROM (v_after->>'raidsVersion') THEN
    RAISE EXCEPTION 'SC-2: raidsVersion changed after heartbeat UPDATE — heartbeat immunity broken';
  END IF;
END; $$ LANGUAGE plpgsql;
DO $$ BEGIN RAISE NOTICE 'SC-2: heartbeat immunity — PASSED'; END; $$;

-- ============================================================
-- SC-3: status transition DOES bump raidsVersion
-- ============================================================
-- Set status_changed_at to a known past value on ALL non-terminal raids first,
-- because now() is constant within a BEGIN/ROLLBACK block and the trigger would
-- produce the same timestamp as the INSERT fixture (both use now()), making the
-- before/after comparison a no-op. We must reset all non-terminal raids because
-- get_queue_sync_state returns MAX(status_changed_at) across all of them — seed
-- data may include other non-terminal raids whose timestamps would mask our
-- sentinel value.
UPDATE public.raids
  SET status_changed_at = '2000-01-01T00:00:00Z'::timestamptz
  WHERE status NOT IN ('completed', 'cancelled');

DO $$
DECLARE
  v_before timestamptz;
  v_after  timestamptz;
BEGIN
  SELECT (public.get_queue_sync_state(NULL)->>'raidsVersion')::timestamptz INTO v_before;
  IF v_before <> '2000-01-01T00:00:00Z'::timestamptz THEN
    RAISE EXCEPTION 'SC-3: precondition failed — status_changed_at was not reset to year-2000 sentinel';
  END IF;
  -- Force a status transition directly (bypassing RPC auth guards in test context).
  UPDATE public.raids SET status = 'lobby'::raid_status_enum WHERE id = '00000000-0000-0000-0000-000000000401';
  SELECT (public.get_queue_sync_state(NULL)->>'raidsVersion')::timestamptz INTO v_after;
  IF v_after IS NOT DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'SC-3: raidsVersion did not change after status transition';
  END IF;
END; $$ LANGUAGE plpgsql;
DO $$ BEGIN RAISE NOTICE 'SC-3: status transition bumps raidsVersion — PASSED'; END; $$;

ROLLBACK;

-- ============================================================
-- ESI-1: boss-queue user gets promoted when invite expires
-- ============================================================
-- Scenario: capacity-1 raid, user 21 has an already-expired invite (120s ago),
-- user 22 is waiting in the boss queue (raid_id IS NULL).
-- expire_stale_invites should revert user 21 to queued and promote user 22
-- from the boss queue into the raid.
-- ============================================================
BEGIN;

INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000305', 'Expire Promote Boss', 5, 997)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-host-011@raidsync.local',    '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-021@raidsync.local',    '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'smoke-user-022@raidsync.local',    '', now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, false)
ON CONFLICT (id) DO NOTHING;

-- Open raid with capacity=1 so confirmed(0) < capacity(1) and the slot is free
INSERT INTO public.raids (
  id, host_user_id, raid_boss_id, location_name,
  start_time, end_time, capacity, is_active, status
)
VALUES (
  '00000000-0000-0000-0000-000000000415',
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000305',
  'ESI-1 Boss Queue Gym',
  now() + interval '30 minutes',
  now() + interval '90 minutes',
  1, true, 'open'
)
ON CONFLICT (id) DO NOTHING;

-- User 21: already-expired invite (120 s ago), fills the single invited slot
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, joined_at, invite_attempts)
VALUES (
  '00000000-0000-0000-0000-000000000621',
  '00000000-0000-0000-0000-000000000415',
  '00000000-0000-0000-0000-000000000021',
  'invited', 1, false,
  now() - interval '120 seconds',
  now() - interval '10 minutes',
  0
)
ON CONFLICT (id) DO NOTHING;

-- User 22: boss-queue entry (no raid yet), waiting 5 min
INSERT INTO public.raid_queues (id, boss_id, user_id, status, position, is_vip, joined_at, invite_attempts)
VALUES (
  '00000000-0000-0000-0000-000000000622',
  '00000000-0000-0000-0000-000000000305',
  '00000000-0000-0000-0000-000000000022',
  'queued', 1, false,
  now() - interval '5 minutes',
  0
)
ON CONFLICT (id) DO NOTHING;

SET LOCAL ROLE authenticated;
-- Call as host (user 11) so that the host's RLS read policy allows selecting
-- both user 21's reverted row and user 22's promoted row in the assertions.
-- expire_stale_invites is SECURITY DEFINER; the caller identity does not affect
-- what the function reads or writes — only the post-call assertions care.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_count    int;
  v_reverted public.raid_queues%ROWTYPE;
  v_promoted public.raid_queues%ROWTYPE;
BEGIN
  SELECT public.expire_stale_invites('00000000-0000-0000-0000-000000000415') INTO v_count;

  IF v_count <= 0 THEN
    RAISE EXCEPTION 'ESI-1: expected return > 0 (at least 1 expired), got %', v_count;
  END IF;

  -- User 21 must be reverted to queued
  SELECT * INTO v_reverted FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000621';
  IF v_reverted.status <> 'queued' THEN
    RAISE EXCEPTION 'ESI-1: user 21 expected status=queued after expire, got %', v_reverted.status;
  END IF;
  IF v_reverted.invited_at IS NOT NULL THEN
    RAISE EXCEPTION 'ESI-1: user 21 invited_at should be NULL after expire, got %', v_reverted.invited_at;
  END IF;

  -- User 22 must be promoted from boss queue into the raid
  SELECT * INTO v_promoted FROM public.raid_queues WHERE id = '00000000-0000-0000-0000-000000000622';
  IF v_promoted.status <> 'invited' THEN
    RAISE EXCEPTION 'ESI-1: user 22 expected status=invited (boss-queue promote), got %', v_promoted.status;
  END IF;
  IF v_promoted.raid_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000415'::uuid THEN
    RAISE EXCEPTION 'ESI-1: user 22 expected raid_id=415, got %', v_promoted.raid_id;
  END IF;
  IF v_promoted.invited_at IS NULL THEN
    RAISE EXCEPTION 'ESI-1: user 22 invited_at should not be NULL after boss-queue promote';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN RAISE NOTICE 'ESI-1: boss-queue promote on expire — PASSED'; END; $$;

ROLLBACK;
