-- Add audit_config JSONB column to app_config and admin RPC to update it.
-- Part of Phase 1: Audit Trail Scaling + Admin Config.

ALTER TABLE public.app_config
  ADD COLUMN audit_config jsonb NOT NULL DEFAULT '{
    "enabled": true,
    "flush_interval_ms": 5000,
    "buffer_max": 50,
    "categories": {
      "session":   true,
      "error":     true,
      "nav":       false,
      "queue":     true,
      "host":      true,
      "lifecycle": true,
      "realtime":  true,
      "data":      false,
      "account":   true,
      "admin":     true
    }
  }'::jsonb;

-- Populate existing row
UPDATE public.app_config
SET audit_config = '{
  "enabled": true,
  "flush_interval_ms": 5000,
  "buffer_max": 50,
  "categories": {
    "session":   true,
    "error":     true,
    "nav":       false,
    "queue":     true,
    "host":      true,
    "lifecycle": true,
    "realtime":  true,
    "data":      false,
    "account":   true,
    "admin":     true
  }
}'::jsonb
WHERE id = 1;

-- Admin-only RPC to update audit_config
CREATE OR REPLACE FUNCTION public.admin_update_audit_config(p_config jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM public.user_profiles
    WHERE auth_id = auth.uid() AND is_admin = true
  ) THEN RAISE EXCEPTION 'Unauthorized'; END IF;

  -- Validate required top-level keys
  IF NOT (p_config ? 'enabled') THEN
    RAISE EXCEPTION 'audit_config must contain "enabled" key'
      USING ERRCODE = '22023';
  END IF;
  IF NOT (p_config ? 'categories') THEN
    RAISE EXCEPTION 'audit_config must contain "categories" key'
      USING ERRCODE = '22023';
  END IF;

  -- Validate categories is an object
  IF jsonb_typeof(p_config -> 'categories') <> 'object' THEN
    RAISE EXCEPTION 'audit_config.categories must be a JSON object'
      USING ERRCODE = '22023';
  END IF;

  -- Validate flush_interval_ms > 0 when present
  IF p_config ? 'flush_interval_ms' THEN
    IF (p_config ->> 'flush_interval_ms')::int <= 0 THEN
      RAISE EXCEPTION 'audit_config.flush_interval_ms must be > 0'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.app_config
  SET audit_config = p_config, updated_at = now()
  WHERE id = 1;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_update_audit_config(jsonb) TO authenticated;
