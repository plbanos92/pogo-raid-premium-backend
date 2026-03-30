-- PHASE 2.5 — Test Seed Data
-- ══════════════════════════════════════════════════════════════════
-- Host:   test-host@raidsync.local   UID: 2959992f-a86e-4f37-8d6a-179d9a861da8
-- Joiner: test-joiner@raidsync.local UID: 396fd0f1-eee5-4c03-b058-1ed2b07dec7c
DO $$
DECLARE
  v_host_id   uuid := '2959992f-a86e-4f37-8d6a-179d9a861da8';
  v_joiner_id uuid := '396fd0f1-eee5-4c03-b058-1ed2b07dec7c';
BEGIN

-- ── 1. Ensure user_profiles exist ─────────────────────────────
INSERT INTO public.user_profiles (auth_id, display_name, friend_code, in_game_name)
VALUES
  (v_host_id,   'TestHost',   '111122223333', 'HostTrainer99'),
  (v_joiner_id, 'TestJoiner', '444455556666', 'JoinerAsh42')
ON CONFLICT (auth_id) DO UPDATE SET
  friend_code   = EXCLUDED.friend_code,
  in_game_name  = EXCLUDED.in_game_name,
  display_name  = EXCLUDED.display_name;

-- ── 2. Ensure VIP subscription for joiner (to test VIP paths) ─
INSERT INTO public.subscriptions (id, user_id, status, is_vip, starts_at)
VALUES ('00000000-0000-0000-0000-000000000301', v_joiner_id, 'active', true, now())
ON CONFLICT (id) DO NOTHING;

-- ── 3. Raid Bosses (upsert — safe if seed.sql already ran) ────
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id, cp, image_url, types) VALUES
  ('00000000-0000-0000-0000-000000000101', 'Mewtwo',      5, 150, 54148, 'https://images.unsplash.com/photo-1659066004091-08e401fe6cfc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400', ARRAY['Psychic']),
  ('00000000-0000-0000-0000-000000000102', 'Rayquaza',    5, 384, 49808, 'https://images.unsplash.com/photo-1762895158802-507fb6d7aa7e?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400', ARRAY['Dragon','Flying']),
  ('00000000-0000-0000-0000-000000000103', 'Mega Gengar', 6, 94,  65553, 'https://images.unsplash.com/photo-1731848671589-820ef3a9552f?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400', ARRAY['Ghost','Poison'])
ON CONFLICT (id) DO NOTHING;

-- ── 4. Test Raids ─────────────────────────────────────────────
-- Raid A: Active lobby (pre-raid) — host manages, joiner is queued
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes)
VALUES ('00000000-0000-0000-0000-00000000aa01', v_host_id, '00000000-0000-0000-0000-000000000101',
        'Central Park Gym', 40.7829, -73.9654, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: active lobby — queued joiner')
ON CONFLICT (id) DO NOTHING;

-- Raid B: Joiner is INVITED (60s countdown test)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes)
VALUES ('00000000-0000-0000-0000-00000000aa02', v_host_id, '00000000-0000-0000-0000-000000000102',
        'Tokyo Tower Gym', 35.6586, 139.7454, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: joiner invited — countdown active')
ON CONFLICT (id) DO NOTHING;

-- Raid C: Joiner is CONFIRMED (waiting for host to start)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes)
VALUES ('00000000-0000-0000-0000-00000000aa03', v_host_id, '00000000-0000-0000-0000-000000000101',
        'Big Ben Gym', 51.5007, -0.1246, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: joiner confirmed — waiting for start')
ON CONFLICT (id) DO NOTHING;

-- Raid D: RAIDING in progress (joiner sees raiding card, host sees 4B panel)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes)
VALUES ('00000000-0000-0000-0000-00000000aa04', v_host_id, '00000000-0000-0000-0000-000000000103',
        'Eiffel Tower Gym', 48.8584, 2.2945, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: raiding in progress')
ON CONFLICT (id) DO NOTHING;

-- Raid E: DONE (joiner finished, host finished — should auto-close on poll)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes, host_finished_at)
VALUES ('00000000-0000-0000-0000-00000000aa05', v_host_id, '00000000-0000-0000-0000-000000000102',
        'Sydney Opera Gym', -33.8568, 151.2153, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: raid done — auto-close pending', now())
ON CONFLICT (id) DO NOTHING;

-- Raid F: Empty lobby (host sees "no one in queue" state)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes)
VALUES ('00000000-0000-0000-0000-00000000aa06', v_host_id, '00000000-0000-0000-0000-000000000103',
        'Colosseum Gym', 41.8902, 12.4922, now() + interval '30 min', now() + interval '90 min', 5, true,
        '111122223333', 'Test: empty lobby — no joiners')
ON CONFLICT (id) DO NOTHING;

-- Raid G: Host inactivity test (lobby full, host idle > 100s)
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng, start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES ('00000000-0000-0000-0000-00000000aa07', v_host_id, '00000000-0000-0000-0000-000000000101',
        'Machu Picchu Gym', -13.1631, -72.5450, now() + interval '30 min', now() + interval '90 min', 2, true,
        '111122223333', 'Test: host inactivity — lobby full, idle > 100s', now() - interval '110 seconds')
ON CONFLICT (id) DO NOTHING;

-- ── 5. Queue Entries ──────────────────────────────────────────
-- Raid A: joiner is queued (Screen 1)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES ('00000000-0000-0000-0000-00000000bb01', '00000000-0000-0000-0000-00000000aa01', v_joiner_id,
        'queued', 1, true, 'Queued entry — Screen 1')
ON CONFLICT (id) DO NOTHING;

-- Raid B: joiner is invited (Screen 2) — set invited_at to ~30s ago for live countdown
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb02', '00000000-0000-0000-0000-00000000aa02', v_joiner_id,
        'invited', 1, true, now() - interval '30 seconds', 'Invited entry — Screen 2, ~30s left')
ON CONFLICT (id) DO NOTHING;

-- Raid C: joiner is confirmed (Screen 3)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb03', '00000000-0000-0000-0000-00000000aa03', v_joiner_id,
        'confirmed', 1, true, now() - interval '45 seconds', 'Confirmed entry — Screen 3')
ON CONFLICT (id) DO NOTHING;

-- Raid D: joiner is raiding (Screen 6)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb04', '00000000-0000-0000-0000-00000000aa04', v_joiner_id,
        'raiding', 1, true, now() - interval '60 seconds', 'Raiding entry — Screen 6')
ON CONFLICT (id) DO NOTHING;

-- Raid E: joiner is done (Screen 7)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb05', '00000000-0000-0000-0000-00000000aa05', v_joiner_id,
        'done', 1, true, now() - interval '90 seconds', 'Done entry — Screen 7')
ON CONFLICT (id) DO NOTHING;

-- Raid G: joiner queued in full lobby (for inactivity test — Screen 5)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES ('00000000-0000-0000-0000-00000000bb07', '00000000-0000-0000-0000-00000000aa07', v_joiner_id,
        'queued', 1, true, 'Full lobby entry — inactivity test')
ON CONFLICT (id) DO NOTHING;
-- Second user to fill the lobby to capacity (capacity=2)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, note)
VALUES ('00000000-0000-0000-0000-00000000bb08', '00000000-0000-0000-0000-00000000aa07', v_host_id,
        'queued', 2, false, 'Filler entry — makes lobby full')
ON CONFLICT (id) DO NOTHING;

END $$;
