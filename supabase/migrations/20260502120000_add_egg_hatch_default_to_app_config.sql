-- Add egg_hatch_default_minutes column to app_config.
-- This controls the default hatch time offset (in minutes) pre-filled
-- when a host enables the egg toggle on the host form.
-- Configurable by admins via admin_update_egg_hatch_default RPC.

ALTER TABLE public.app_config
  ADD COLUMN IF NOT EXISTS egg_hatch_default_minutes int NOT NULL DEFAULT 30;

COMMENT ON COLUMN public.app_config.egg_hatch_default_minutes IS
  'Default number of minutes ahead to pre-fill the hatch time input when '
  'a host enables the egg toggle. Admins can change this via the admin settings tab.';

-- RPC: admin_update_egg_hatch_default
-- Only callable by admins (checked via profiles.is_admin).
CREATE OR REPLACE FUNCTION public.admin_update_egg_hatch_default(p_minutes int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Require admin
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_minutes < 1 OR p_minutes > 1440 THEN
    RAISE EXCEPTION 'egg_hatch_default_minutes must be between 1 and 1440';
  END IF;

  UPDATE public.app_config
    SET egg_hatch_default_minutes = p_minutes,
        updated_at = now()
    WHERE id = 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_egg_hatch_default(int) TO authenticated;
