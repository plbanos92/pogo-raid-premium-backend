-- PHASE 2.5 — Refresh Test Seed Data
-- ══════════════════════════════════════════════════════════════════
-- Fixes "Hosting: Unknown" by force-upserting all test rows so that
-- raids always reference valid raid_boss_id values.
-- Also refreshes timestamps and aligns statuses with the full
-- state machine (queued → invited → confirmed → raiding → done).
--
-- Host:   test-host@raidsync.local   UID: 2959992f-a86e-4f37-8d6a-179d9a861da8
-- Joiner: test-joiner@raidsync.local UID: 396fd0f1-eee5-4c03-b058-1ed2b07dec7c
DO $$
DECLARE
  v_host_id   uuid := '2959992f-a86e-4f37-8d6a-179d9a861da8';
  v_joiner_id uuid := '396fd0f1-eee5-4c03-b058-1ed2b07dec7c';

  -- Boss IDs (deterministic)
  v_boss_mewtwo   uuid := '00000000-0000-0000-0000-000000000101';
  v_boss_rayquaza uuid := '00000000-0000-0000-0000-000000000102';
  v_boss_gengar   uuid := '00000000-0000-0000-0000-000000000103';
  v_boss_groudon  uuid := '00000000-0000-0000-0000-000000000104';
  v_boss_kyogre   uuid := '00000000-0000-0000-0000-000000000105';

  -- Raid IDs (deterministic)
  v_raid_a uuid := '00000000-0000-0000-0000-00000000aa01';  -- queued
  v_raid_b uuid := '00000000-0000-0000-0000-00000000aa02';  -- invited
  v_raid_c uuid := '00000000-0000-0000-0000-00000000aa03';  -- confirmed
  v_raid_d uuid := '00000000-0000-0000-0000-00000000aa04';  -- raiding
  v_raid_e uuid := '00000000-0000-0000-0000-00000000aa05';  -- done (host+joiner finished)
  v_raid_f uuid := '00000000-0000-0000-0000-00000000aa06';  -- empty lobby
  v_raid_g uuid := '00000000-0000-0000-0000-00000000aa07';  -- host inactivity (full lobby, idle)

BEGIN

-- ── 1. User profiles (ensure fresh data + new columns) ────────
INSERT INTO public.user_profiles (auth_id, display_name, friend_code, in_game_name, trainer_level, team)
VALUES
  (v_host_id,   'TestHost',   '111122223333', 'HostTrainer99', 40, 'valor'),
  (v_joiner_id, 'TestJoiner', '444455556666', 'JoinerAsh42',   36, 'mystic')
ON CONFLICT (auth_id) DO UPDATE SET
  display_name   = EXCLUDED.display_name,
  friend_code    = EXCLUDED.friend_code,
  in_game_name   = EXCLUDED.in_game_name,
  trainer_level  = EXCLUDED.trainer_level,
  team           = EXCLUDED.team;

-- ── 2. VIP subscription for joiner ────────────────────────────
INSERT INTO public.subscriptions (id, user_id, status, is_vip, starts_at)
VALUES ('00000000-0000-0000-0000-000000000301', v_joiner_id, 'active', true, now())
ON CONFLICT (id) DO UPDATE SET
  status  = 'active',
  is_vip  = true;

-- ── 3. Raid Bosses — force upsert so FK always resolves ───────
-- Using DO UPDATE SET ensures raid_boss_id FK joins always return
-- data and never produce "Hosting: Unknown".
INSERT INTO public.raid_bosses (id, name, tier, pokemon_id, cp, image_url, types, is_visible, available_from, available_until)
VALUES
  (v_boss_mewtwo,
   'Mewtwo', 5, 150, 54148,
   'https://images.unsplash.com/photo-1659066004091-08e401fe6cfc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
   ARRAY['Psychic'], true, NULL, NULL),

  (v_boss_rayquaza,
   'Rayquaza', 5, 384, 49808,
   'https://images.unsplash.com/photo-1762895158802-507fb6d7aa7e?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
   ARRAY['Dragon', 'Flying'], true, NULL, NULL),

  (v_boss_gengar,
   'Mega Gengar', 6, 94, 65553,
   'https://images.unsplash.com/photo-1731848671589-820ef3a9552f?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
   ARRAY['Ghost', 'Poison'], true, NULL, NULL),

  (v_boss_groudon,
   'Groudon', 5, 383, 53394,
   'https://images.unsplash.com/photo-1697543757168-c4e016db28fe?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
   ARRAY['Ground'], true, NULL, NULL),

  (v_boss_kyogre,
   'Kyogre', 5, 382, 52440,
   'https://images.unsplash.com/photo-1729289190939-6da5b8e7d2dd?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
   ARRAY['Water'], true, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET
  name           = EXCLUDED.name,
  tier           = EXCLUDED.tier,
  pokemon_id     = EXCLUDED.pokemon_id,
  cp             = EXCLUDED.cp,
  image_url      = EXCLUDED.image_url,
  types          = EXCLUDED.types,
  is_visible     = true,
  available_from  = NULL,
  available_until = NULL;

-- ── 4. Raids — force upsert with valid boss IDs + fresh times ──
-- Raid A: Active lobby — joiner queued, host ready to invite
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_a, v_host_id, v_boss_mewtwo,
  'Central Park Gym', 40.7829, -73.9654,
  now() + interval '30 min', now() + interval '90 min',
  5, true, '111122223333', 'Test A: active lobby — joiner queued', now())
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_mewtwo,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() + interval '30 min',
  end_time            = now() + interval '90 min',
  last_host_action_at = now(),
  host_finished_at    = NULL;

-- Raid B: Joiner is INVITED — 60s countdown live
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_b, v_host_id, v_boss_rayquaza,
  'Tokyo Tower Gym', 35.6586, 139.7454,
  now() + interval '30 min', now() + interval '90 min',
  5, true, '111122223333', 'Test B: joiner invited — countdown active', now())
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_rayquaza,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() + interval '30 min',
  end_time            = now() + interval '90 min',
  last_host_action_at = now(),
  host_finished_at    = NULL;

-- Raid C: Joiner is CONFIRMED — waiting for host to start
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_c, v_host_id, v_boss_mewtwo,
  'Big Ben Gym', 51.5007, -0.1246,
  now() + interval '30 min', now() + interval '90 min',
  5, true, '111122223333', 'Test C: joiner confirmed — waiting for start', now())
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_mewtwo,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() + interval '30 min',
  end_time            = now() + interval '90 min',
  last_host_action_at = now(),
  host_finished_at    = NULL;

-- Raid D: RAIDING in progress — all confirmed entries started
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_d, v_host_id, v_boss_gengar,
  'Eiffel Tower Gym', 48.8584, 2.2945,
  now() - interval '10 min', now() + interval '50 min',
  5, true, '111122223333', 'Test D: raiding in progress', now())
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_gengar,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() - interval '10 min',
  end_time            = now() + interval '50 min',
  last_host_action_at = now(),
  host_finished_at    = NULL;

-- Raid E: DONE — host finished, joiner done → auto-close pending
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at, host_finished_at)
VALUES (v_raid_e, v_host_id, v_boss_kyogre,
  'Sydney Opera Gym', -33.8568, 151.2153,
  now() - interval '20 min', now() + interval '40 min',
  5, true, '111122223333', 'Test E: raid done — host + joiner finished', now() - interval '5 min', now() - interval '2 min')
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_kyogre,
  is_active           = false,
  friend_code         = '111122223333',
  last_host_action_at = now() - interval '5 min',
  host_finished_at    = now() - interval '2 min';

-- Raid F: Empty lobby — host waiting, no joiners yet
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_f, v_host_id, v_boss_groudon,
  'Colosseum Gym', 41.8902, 12.4922,
  now() + interval '20 min', now() + interval '80 min',
  5, true, '111122223333', 'Test F: empty lobby — no joiners', now())
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_groudon,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() + interval '20 min',
  end_time            = now() + interval '80 min',
  last_host_action_at = now(),
  host_finished_at    = NULL;

-- Raid G: Host inactivity — lobby full (capacity=2), host idle > 100s
INSERT INTO public.raids (id, host_user_id, raid_boss_id, location_name, lat, lng,
  start_time, end_time, capacity, is_active, friend_code, notes, last_host_action_at)
VALUES (v_raid_g, v_host_id, v_boss_mewtwo,
  'Machu Picchu Gym', -13.1631, -72.5450,
  now() + interval '15 min', now() + interval '75 min',
  2, true, '111122223333', 'Test G: host inactivity — lobby full, idle > 100s', now() - interval '110 seconds')
ON CONFLICT (id) DO UPDATE SET
  raid_boss_id        = v_boss_mewtwo,
  is_active           = true,
  friend_code         = '111122223333',
  start_time          = now() + interval '15 min',
  end_time            = now() + interval '75 min',
  last_host_action_at = now() - interval '110 seconds',
  host_finished_at    = NULL;

-- ── 5. Queue entries — force upsert with correct statuses ─────
-- Note: ON CONFLICT on 'id' (primary key).
-- Trigger trg_set_invited_at fires on INSERT+status='invited',
-- so we set invited_at explicitly to avoid trigger conflict on UPDATE.

-- Raid A: joiner queued (State 1 — waiting in line)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb01', v_raid_a, v_joiner_id,
        'queued', 1, true, now() - interval '2 min', NULL,
        'State 1: queued — waiting in line')
ON CONFLICT (id) DO UPDATE SET
  raid_id    = v_raid_a,
  status     = 'queued',
  is_vip     = true,
  joined_at  = now() - interval '2 min',
  invited_at = NULL;

-- Raid B: joiner invited (State 2 — ~30s into 60s window)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb02', v_raid_b, v_joiner_id,
        'invited', 1, true, now() - interval '5 min', now() - interval '30 seconds',
        'State 2: invited — ~30s remaining in 60s window')
ON CONFLICT (id) DO UPDATE SET
  raid_id    = v_raid_b,
  status     = 'invited',
  is_vip     = true,
  joined_at  = now() - interval '5 min',
  invited_at = now() - interval '30 seconds';

-- Raid C: joiner confirmed (State 3 — responded, waiting for host to start)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb03', v_raid_c, v_joiner_id,
        'confirmed', 1, true, now() - interval '8 min', now() - interval '6 min',
        'State 3: confirmed — friend request sent, waiting for start_raid')
ON CONFLICT (id) DO UPDATE SET
  raid_id    = v_raid_c,
  status     = 'confirmed',
  is_vip     = true,
  joined_at  = now() - interval '8 min',
  invited_at = now() - interval '6 min';

-- Raid D: joiner raiding (State 4 — raid in progress)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb04', v_raid_d, v_joiner_id,
        'raiding', 1, true, now() - interval '15 min', now() - interval '12 min',
        'State 4: raiding — raid in progress, finish button visible')
ON CONFLICT (id) DO UPDATE SET
  raid_id    = v_raid_d,
  status     = 'raiding',
  is_vip     = true,
  joined_at  = now() - interval '15 min',
  invited_at = now() - interval '12 min';

-- Raid E: joiner done (State 5 — finished raiding)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, invited_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb05', v_raid_e, v_joiner_id,
        'done', 1, true, now() - interval '25 min', now() - interval '22 min',
        'State 5: done — joiner finished raiding')
ON CONFLICT (id) DO UPDATE SET
  raid_id    = v_raid_e,
  status     = 'done',
  is_vip     = true,
  joined_at  = now() - interval '25 min',
  invited_at = now() - interval '22 min';

-- Raid G: two joiners to fill capacity=2 (host inactivity test)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb07', v_raid_g, v_joiner_id,
        'queued', 1, true, now() - interval '5 min',
        'State G-1: queued — full lobby, inactivity test')
ON CONFLICT (id) DO UPDATE SET
  raid_id   = v_raid_g,
  status    = 'queued',
  is_vip    = true,
  joined_at = now() - interval '5 min';

-- Second entry to reach capacity=2 (using host as stand-in joiner)
INSERT INTO public.raid_queues (id, raid_id, user_id, status, position, is_vip, joined_at, note)
VALUES ('00000000-0000-0000-0000-00000000bb08', v_raid_g, v_host_id,
        'queued', 2, false, now() - interval '4 min',
        'State G-2: queued — filler to hit capacity, inactivity test')
ON CONFLICT (id) DO UPDATE SET
  raid_id   = v_raid_g,
  status    = 'queued',
  is_vip    = false,
  joined_at = now() - interval '4 min';

END $$;
