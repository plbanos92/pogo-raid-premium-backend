-- Replace PNG silhouette image_url values with animated GIF silhouettes.
-- GIFs are derived from sprites/sprites/pokemon/other/showdown/ via ImageMagick
-- silhouette conversion and served as Cloudflare Worker static assets.
--
-- Bosses updated: Mega Gengar (94), Mewtwo (150), Lugia (249), Ho-Oh (250),
--                 Kyogre (382), Groudon (383), Rayquaza (384)

UPDATE public.raid_bosses
SET image_url = 'https://pogo-raid-premium.plbanos92.workers.dev/assets/silhouettes/gif/' || pokemon_id::text || '.gif'
WHERE pokemon_id IN (94, 150, 249, 250, 382, 383, 384);
