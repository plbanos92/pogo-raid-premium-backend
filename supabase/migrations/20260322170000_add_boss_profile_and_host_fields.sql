-- Add rich profile fields to raid_bosses to match Figma design screens.
-- Adds: image_url, cp, types array.
-- Adds: friend_code to user_profiles and raids.
-- Creates: boss_queue_stats view for aggregated boss data.
-- Creates: join_boss_queue RPC to route users to best available raid.

ALTER TABLE "raid_bosses"
  ADD COLUMN IF NOT EXISTS "image_url" text,
  ADD COLUMN IF NOT EXISTS "cp"        int,
  ADD COLUMN IF NOT EXISTS "types"     text[] DEFAULT '{}';

ALTER TABLE "user_profiles"
  ADD COLUMN IF NOT EXISTS "friend_code" text;

ALTER TABLE "raids"
  ADD COLUMN IF NOT EXISTS "friend_code" text;

-- ─── View: per-boss aggregated stats ─────────────────────────────────────────
-- Returns active_hosts = active raid count, queue_length = queued/invited entries.
CREATE OR REPLACE VIEW "boss_queue_stats" AS
SELECT
  rb.id,
  rb.name,
  rb.tier,
  rb.cp,
  rb.image_url,
  rb.types,
  rb.pokemon_id,
  COALESCE((
    SELECT COUNT(*)::int
    FROM raids r
    WHERE r.raid_boss_id = rb.id
      AND r.is_active = true
  ), 0) AS active_hosts,
  COALESCE((
    SELECT COUNT(*)::int
    FROM raid_queues q
    JOIN raids r ON r.id = q.raid_id
    WHERE r.raid_boss_id = rb.id
      AND r.is_active = true
      AND q.status IN ('queued', 'invited')
  ), 0) AS queue_length
FROM "raid_bosses" rb;

GRANT SELECT ON "boss_queue_stats" TO anon, authenticated;

-- ─── RPC: join_boss_queue ─────────────────────────────────────────────────────
-- Finds the active raid with the most participants (but still has capacity)
-- for the requested boss and proxies to join_raid_queue.
CREATE OR REPLACE FUNCTION public.join_boss_queue(
  p_boss_id uuid,
  p_note    text DEFAULT NULL
)
RETURNS public.raid_queues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_raid_id uuid;
  v_result  public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  -- Pick the active raid for this boss with space, preferring the most-populated
  -- one so hosts don't sit idle.
  SELECT r.id INTO v_raid_id
  FROM raids r
  WHERE r.raid_boss_id = p_boss_id
    AND r.is_active = true
    AND (
      SELECT COUNT(*)
      FROM raid_queues q
      WHERE q.raid_id = r.id
        AND q.status IN ('queued', 'invited', 'confirmed')
    ) < r.capacity
  ORDER BY (
    SELECT COUNT(*)
    FROM raid_queues q
    WHERE q.raid_id = r.id
      AND q.status IN ('queued', 'invited', 'confirmed')
  ) DESC
  LIMIT 1;

  IF v_raid_id IS NULL THEN
    RAISE EXCEPTION 'No active raid available for this boss'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_result FROM public.join_raid_queue(v_raid_id, p_note);
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.join_boss_queue(uuid, text) TO authenticated;
