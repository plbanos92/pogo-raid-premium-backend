-- Replace placeholder Unsplash image_url values with proper Pokemon silhouette
-- PNGs served from the Cloudflare Worker static assets.
-- New URLs point to /assets/silhouettes/png/{pokemon_id}.png which are
-- generated from official-artwork sprites and deployed with the frontend build.
--
-- Bosses updated: Mega Gengar (94), Mewtwo (150), Lugia (249), Ho-Oh (250),
--                 Kyogre (382), Groudon (383), Rayquaza (384)

UPDATE public.raid_bosses
SET image_url = 'https://pogo-raid-premium.plbanos92.workers.dev/assets/silhouettes/png/' || pokemon_id::text || '.png'
WHERE pokemon_id IN (94, 150, 249, 250, 382, 383, 384);
