-- Deterministic starter data for local/dev testing.

INSERT INTO "raid_bosses" ("id", "name", "tier", "pokemon_id")
VALUES
  ('00000000-0000-0000-0000-000000000101', 'Mewtwo', 5, 150),
  ('00000000-0000-0000-0000-000000000102', 'Rayquaza', 5, 384),
  ('00000000-0000-0000-0000-000000000103', 'Mega Gengar', 6, 94)
ON CONFLICT ("id") DO NOTHING;

-- Optional raid fixture for unauthenticated read checks may remain hidden by RLS.
INSERT INTO "raids" (
  "id",
  "host_user_id",
  "raid_boss_id",
  "location_name",
  "lat",
  "lng",
  "start_time",
  "end_time",
  "capacity",
  "is_active",
  "notes"
)
VALUES (
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000101',
  'Shibuya Crossing Gym',
  35.6595,
  139.7005,
  now() + interval '1 hour',
  now() + interval '2 hours',
  20,
  true,
  'Seed raid for local testing'
)
ON CONFLICT ("id") DO NOTHING;
