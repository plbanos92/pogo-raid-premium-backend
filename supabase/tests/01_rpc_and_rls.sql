\set ON_ERROR_STOP on

BEGIN;

-- Fixture setup executed as elevated role.
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id)
VALUES ('00000000-0000-0000-0000-000000000301', 'Test Boss', 5, 999)
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

-- Raid with is_active=true but status='completed': join_raid_queue must reject it
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
  FROM public.join_raid_queue('00000000-0000-0000-0000-000000000401', 'smoke-user-join');

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000021'::uuid THEN
    RAISE EXCEPTION 'join_raid_queue returned unexpected user_id';
  END IF;

  IF v_queue.status <> 'invited' THEN
    RAISE EXCEPTION 'join_raid_queue expected status invited, got %', v_queue.status;
  END IF;

  IF v_queue.invited_at IS NULL THEN
    RAISE EXCEPTION 'join_raid_queue expected invited_at to be set for auto-filled join';
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

-- Idempotency check: second join returns same row for same user+raid.
DO $$
DECLARE
  v_first public.raid_queues%ROWTYPE;
  v_second public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_first
  FROM public.join_raid_queue('00000000-0000-0000-0000-000000000401', NULL);

  SELECT * INTO v_second
  FROM public.join_raid_queue('00000000-0000-0000-0000-000000000401', NULL);

  IF v_first.id <> v_second.id THEN
    RAISE EXCEPTION 'join_raid_queue is not idempotent for same user and raid';
  END IF;

  IF v_second.status <> 'invited' THEN
    RAISE EXCEPTION 'join_raid_queue idempotent return expected invited status, got %', v_second.status;
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

-- Test 1: join_boss_queue must reject a raid in 'raiding' state even when
-- is_active = true.  After Phase 3 the selector uses status IN ('open','lobby');
-- raid 406 has status='raiding' so no eligible raid exists for boss 302.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.join_boss_queue('00000000-0000-0000-0000-000000000302');
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION
      'Phase 3: join_boss_queue should reject a raiding raid (is_active=true, status=raiding)';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 2a: join_raid_queue must reject a raid with status='completed' even when
-- is_active = true (raid 407 is intentionally inconsistent to isolate the predicate).
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.join_raid_queue('00000000-0000-0000-0000-000000000407');
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' OR SQLERRM LIKE '%inactive%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION
      'Phase 3: join_raid_queue should reject a completed raid with is_active=true';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 2b: join_raid_queue must reject a raid with status='cancelled' even when
-- is_active = true (raid 408).
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.join_raid_queue('00000000-0000-0000-0000-000000000408');
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' OR SQLERRM LIKE '%inactive%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION
      'Phase 3: join_raid_queue should reject a cancelled raid with is_active=true';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Test 3a: A user who previously left a raid can re-join it while it is open.
-- Raid 409 has a pre-seeded 'left' entry for user 21; Phase 3 deletes that
-- stale row and issues a fresh enrollment into 'invited' status.
DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_raid_queue(
    '00000000-0000-0000-0000-000000000409',
    'smoke-phase3-left-rejoin'
  );

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000021'::uuid THEN
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

-- Test 3b: A user whose queue slot was 'cancelled' can also re-join an open raid.
-- Raid 409 has a pre-seeded 'cancelled' entry for user 22; this is the primary
-- regression caught by change 1b (cancelled was previously treated as a blocker).
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000022', true);

DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_raid_queue(
    '00000000-0000-0000-0000-000000000409',
    'smoke-phase3-cancelled-rejoin'
  );

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000022'::uuid THEN
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
  'invited',
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
