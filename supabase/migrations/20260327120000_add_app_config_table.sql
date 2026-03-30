-- App-wide configuration table.
-- Single row (enforced by CHECK). Push a new migration to change any value.
-- Never edit this migration — create a new one to update values.

CREATE TABLE IF NOT EXISTS public.app_config (
  id                      int PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- enforces single row
  -- Host capacity caps
  host_capacity_free      int  NOT NULL DEFAULT 5,
  host_capacity_vip       int  NOT NULL DEFAULT 10,
  -- Subscription pricing (display only — no billing integration)
  vip_price               text NOT NULL DEFAULT '$4.99',
  vip_price_period        text NOT NULL DEFAULT '/mo',
  -- Invite response window in seconds (must match expire_stale_invites RPC)
  invite_window_seconds   int  NOT NULL DEFAULT 60,
  -- Host inactivity timeout in seconds (must match check_host_inactivity RPC)
  host_inactivity_seconds int  NOT NULL DEFAULT 100,
  -- VIP feature list shown on the subscription page (JSONB array)
  -- Each element: { "icon": "<icon-key>", "text": "<display string>" }
  vip_features            jsonb NOT NULL DEFAULT '[
    {"icon":"zap",    "text":"Priority Queue Placement"},
    {"icon":"star",   "text":"Host up to 10 players"},
    {"icon":"shield", "text":"Ad-free experience"},
    {"icon":"crown",  "text":"Exclusive Discord role"}
  ]'::jsonb,
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- Seed the initial row
INSERT INTO public.app_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Enable RLS (consistent with all other public tables)
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Allow all users (including anon) to read config
CREATE POLICY "app_config_select_all"
  ON public.app_config
  FOR SELECT
  USING (true);

-- Read-only for everyone — only migrations can change values
GRANT SELECT ON TABLE public.app_config TO anon, authenticated;

COMMENT ON TABLE public.app_config IS
  'Single-row app configuration. To change a value, create a new migration
   with UPDATE public.app_config SET ... WHERE id = 1.
   Never edit this migration directly.';
