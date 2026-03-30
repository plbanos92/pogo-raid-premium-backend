-- Assign unique raid bosses to each Phase 2.5 state-machine fixture.
-- Previous test data reused bosses across multiple state screens, which made
-- the seeded host/joiner scenarios harder to distinguish during QA.

DO $$
DECLARE
  v_boss_mewtwo   uuid := '00000000-0000-0000-0000-000000000101';
  v_boss_rayquaza uuid := '00000000-0000-0000-0000-000000000102';
  v_boss_gengar   uuid := '00000000-0000-0000-0000-000000000103';
  v_boss_groudon  uuid := '00000000-0000-0000-0000-000000000104';
  v_boss_kyogre   uuid := '00000000-0000-0000-0000-000000000105';
  v_boss_lugia    uuid := '00000000-0000-0000-0000-000000000106';
  v_boss_ho_oh    uuid := '00000000-0000-0000-0000-000000000107';

  v_raid_a uuid := '00000000-0000-0000-0000-00000000aa01';
  v_raid_b uuid := '00000000-0000-0000-0000-00000000aa02';
  v_raid_c uuid := '00000000-0000-0000-0000-00000000aa03';
  v_raid_d uuid := '00000000-0000-0000-0000-00000000aa04';
  v_raid_e uuid := '00000000-0000-0000-0000-00000000aa05';
  v_raid_f uuid := '00000000-0000-0000-0000-00000000aa06';
  v_raid_g uuid := '00000000-0000-0000-0000-00000000aa07';
BEGIN
  INSERT INTO public.raid_bosses (id, name, tier, pokemon_id, cp, image_url, types, is_visible, available_from, available_until)
  VALUES
    (v_boss_lugia,
     'Lugia', 5, 249, 41853,
     'https://images.unsplash.com/photo-1709083707261-73a6b0f1df95?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
     ARRAY['Psychic', 'Flying'], true, NULL, NULL),
    (v_boss_ho_oh,
     'Ho-Oh', 5, 250, 50064,
     'https://images.unsplash.com/photo-1732898643734-3f1af0f6fa6d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&w=400',
     ARRAY['Fire', 'Flying'], true, NULL, NULL)
  ON CONFLICT (id) DO UPDATE SET
    name            = EXCLUDED.name,
    tier            = EXCLUDED.tier,
    pokemon_id      = EXCLUDED.pokemon_id,
    cp              = EXCLUDED.cp,
    image_url       = EXCLUDED.image_url,
    types           = EXCLUDED.types,
    is_visible      = true,
    available_from  = NULL,
    available_until = NULL;

  -- Keep one distinct boss per seeded state-machine raid:
  -- A queued, B invited, C confirmed, D raiding, E done, F empty, G inactivity.
  UPDATE public.raids
  SET raid_boss_id = CASE id
    WHEN v_raid_a THEN v_boss_mewtwo
    WHEN v_raid_b THEN v_boss_rayquaza
    WHEN v_raid_c THEN v_boss_gengar
    WHEN v_raid_d THEN v_boss_groudon
    WHEN v_raid_e THEN v_boss_kyogre
    WHEN v_raid_f THEN v_boss_lugia
    WHEN v_raid_g THEN v_boss_ho_oh
    ELSE raid_boss_id
  END
  WHERE id IN (v_raid_a, v_raid_b, v_raid_c, v_raid_d, v_raid_e, v_raid_f, v_raid_g);
END $$;