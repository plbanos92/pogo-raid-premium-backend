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

SET LOCAL ROLE authenticated;

-- User joins queue and receives deterministic queued status.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_queue public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.join_raid_queue('00000000-0000-0000-0000-000000000401', 'smoke-user-join');

  IF v_queue.user_id <> '00000000-0000-0000-0000-000000000021'::uuid THEN
    RAISE EXCEPTION 'join_raid_queue returned unexpected user_id';
  END IF;

  IF v_queue.status <> 'queued' THEN
    RAISE EXCEPTION 'join_raid_queue expected status queued, got %', v_queue.status;
  END IF;
END;
$$ LANGUAGE plpgsql;

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
END;
$$ LANGUAGE plpgsql;

-- Host invites and confirms next queued user.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

DO $$
DECLARE
  v_invited public.raid_queues%ROWTYPE;
  v_confirmed public.raid_queues%ROWTYPE;
BEGIN
  SELECT * INTO v_invited
  FROM public.host_invite_next_in_queue('00000000-0000-0000-0000-000000000401');

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

ROLLBACK;
