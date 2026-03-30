-- ─────────────────────────────────────────────────────────────
-- Migration I: Boss scheduling + admin management
-- Phase 5 — Admin Boss Management
-- ─────────────────────────────────────────────────────────────

-- Add scheduling columns to raid_bosses
ALTER TABLE public.raid_bosses
  ADD COLUMN IF NOT EXISTS available_from  timestamptz,
  ADD COLUMN IF NOT EXISTS available_until timestamptz,
  ADD COLUMN IF NOT EXISTS is_visible      boolean NOT NULL DEFAULT true;

-- Add is_admin flag to user_profiles
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;

-- ─────────────────────────────────────────────────────────────
-- Helper: check if calling user is an admin
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_caller_admin()
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE auth_id = auth.uid() AND is_admin = true
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- Recreate boss_queue_stats view with scheduling filter
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.boss_queue_stats AS
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
    FROM public.raids r
    WHERE r.raid_boss_id = rb.id AND r.is_active = true
  ), 0) AS active_hosts,
  COALESCE((
    SELECT COUNT(*)::int
    FROM public.raid_queues q
    JOIN public.raids r ON r.id = q.raid_id
    WHERE r.raid_boss_id = rb.id
      AND r.is_active = true
      AND q.status IN ('queued', 'invited')
  ), 0) AS queue_length
FROM public.raid_bosses rb
WHERE rb.is_visible = true
  AND (rb.available_from IS NULL OR rb.available_from <= now())
  AND (rb.available_until IS NULL OR rb.available_until > now());

GRANT SELECT ON public.boss_queue_stats TO anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Admin RPC: create a new raid boss
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_create_boss(
  p_name          text,
  p_tier          int          DEFAULT NULL,
  p_pokemon_id    int          DEFAULT NULL,
  p_cp            int          DEFAULT NULL,
  p_image_url     text         DEFAULT NULL,
  p_types         text[]       DEFAULT '{}',
  p_available_from  timestamptz  DEFAULT NULL,
  p_available_until timestamptz  DEFAULT NULL,
  p_is_visible    boolean      DEFAULT true
)
RETURNS public.raid_bosses
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_boss public.raid_bosses%ROWTYPE;
BEGIN
  IF NOT public.is_caller_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  IF p_available_until IS NOT NULL AND p_available_from IS NOT NULL
     AND p_available_until <= p_available_from THEN
    RAISE EXCEPTION 'available_until must be after available_from';
  END IF;
  INSERT INTO public.raid_bosses (
    name, tier, pokemon_id, cp, image_url, types,
    available_from, available_until, is_visible
  ) VALUES (
    p_name, p_tier, p_pokemon_id, p_cp, p_image_url, p_types,
    p_available_from, p_available_until, p_is_visible
  )
  RETURNING * INTO v_boss;
  RETURN v_boss;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_boss(
  text, int, int, int, text, text[], timestamptz, timestamptz, boolean
) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- Admin RPC: update an existing raid boss (COALESCE — NULL = no change)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_boss(
  p_boss_id       uuid,
  p_name          text         DEFAULT NULL,
  p_tier          int          DEFAULT NULL,
  p_pokemon_id    int          DEFAULT NULL,
  p_cp            int          DEFAULT NULL,
  p_image_url     text         DEFAULT NULL,
  p_types         text[]       DEFAULT NULL,
  p_available_from  timestamptz  DEFAULT NULL,
  p_available_until timestamptz  DEFAULT NULL,
  p_is_visible    boolean      DEFAULT NULL
)
RETURNS public.raid_bosses
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_boss public.raid_bosses%ROWTYPE;
BEGIN
  IF NOT public.is_caller_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_boss FROM public.raid_bosses WHERE id = p_boss_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Boss not found';
  END IF;
  UPDATE public.raid_bosses SET
    name          = COALESCE(p_name, name),
    tier          = COALESCE(p_tier, tier),
    pokemon_id    = COALESCE(p_pokemon_id, pokemon_id),
    cp            = COALESCE(p_cp, cp),
    image_url     = COALESCE(p_image_url, image_url),
    types         = COALESCE(p_types, types),
    available_from  = COALESCE(p_available_from, available_from),
    available_until = COALESCE(p_available_until, available_until),
    is_visible    = COALESCE(p_is_visible, is_visible)
  WHERE id = p_boss_id
  RETURNING * INTO v_boss;
  RETURN v_boss;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_boss(
  uuid, text, int, int, int, text, text[], timestamptz, timestamptz, boolean
) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- Admin RPC: list ALL bosses (including hidden/expired/scheduled)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_list_all_bosses()
RETURNS SETOF public.raid_bosses
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.is_caller_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT * FROM public.raid_bosses
    ORDER BY available_from DESC NULLS LAST, name ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_all_bosses() TO authenticated;
