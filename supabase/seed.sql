-- Deterministic starter data for local/dev testing.

INSERT INTO "raid_bosses" ("id", "name", "tier", "pokemon_id", "cp", "image_url", "types")
VALUES
  (
    '00000000-0000-0000-0000-000000000101',
    'Mewtwo', 5, 150, 54148,
    'https://images.unsplash.com/photo-1659066004091-08e401fe6cfc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
    ARRAY['Psychic']
  ),
  (
    '00000000-0000-0000-0000-000000000102',
    'Rayquaza', 5, 384, 49808,
    'https://images.unsplash.com/photo-1762895158802-507fb6d7aa7e?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
    ARRAY['Dragon', 'Flying']
  ),
  (
    '00000000-0000-0000-0000-000000000103',
    'Mega Gengar', 6, 94, 65553,
    'https://images.unsplash.com/photo-1731848671589-820ef3a9552f?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
    ARRAY['Ghost', 'Poison']
  )
ON CONFLICT ("id") DO UPDATE SET
  "cp"        = EXCLUDED."cp",
  "image_url" = EXCLUDED."image_url",
  "types"     = EXCLUDED."types";

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
