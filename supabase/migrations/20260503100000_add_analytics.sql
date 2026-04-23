-- Migration: Analytics / page_views tracking
-- Stores every page-view hit (anonymous or authenticated) with privacy-respecting
-- metadata. Raw IP addresses are NEVER stored — the Worker hashes them before
-- insertion. No email, no name, no precise coordinates.
--
-- Security model:
--   * INSERT: allowed to both anon and authenticated. This is how analytics
--     beacons arrive from the Worker.
--   * SELECT: admins only (via user_profiles.is_admin).
--   * UPDATE/DELETE: admins only.
--   * BEFORE INSERT trigger auto-populates user_id from auth.uid() so clients
--     cannot spoof the logged-in user.
--
-- CORS note: the client never calls PostgREST directly. All traffic goes
-- through the Cloudflare Worker at /api/track which is same-origin.

BEGIN;

CREATE TABLE IF NOT EXISTS public.page_views (
  id               bigserial PRIMARY KEY,
  created_at       timestamptz NOT NULL DEFAULT now(),

  -- Identity (non-PII)
  visitor_id       text,                 -- persistent UUID from localStorage
  session_id       text,                 -- UUID from sessionStorage
  user_id          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ip_hash          text,                 -- SHA-256(ip + salt), set server-side

  -- Request context
  event_type       text NOT NULL DEFAULT 'pageview',  -- 'pageview' | 'view_change' | 'init' | 'custom'
  path             text,                 -- window.location.pathname
  view_name        text,                 -- in-app state.view (home/host/queues/...)
  referrer         text,
  referrer_host    text,                 -- derived host only, e.g. 'google.com'

  -- Client environment
  user_agent       text,
  browser          text,                 -- client-parsed: Chrome / Safari / Firefox / ...
  browser_version  text,
  os               text,                 -- Windows / macOS / iOS / Android / Linux
  os_version       text,
  device_type      text,                 -- mobile / tablet / desktop
  language         text,
  languages        text,                 -- comma-joined
  timezone         text,
  timezone_offset  integer,              -- minutes east of UTC
  screen_w         integer,
  screen_h         integer,
  viewport_w       integer,
  viewport_h       integer,
  dpr              real,
  color_depth      integer,
  is_standalone    boolean,              -- PWA display-mode: standalone
  is_touch         boolean,
  prefers_dark     boolean,
  connection_type  text,
  effective_type   text,
  downlink         real,
  hardware_concurrency integer,
  device_memory    real,
  platform         text,
  vendor           text,

  -- Server-side enrichment (from Cloudflare request.cf)
  country          text,
  region           text,
  city             text,
  continent        text,
  colo             text,                 -- CF PoP code
  asn              integer,
  as_organization  text,

  -- Catch-all for future fields
  extra            jsonb
);

CREATE INDEX IF NOT EXISTS idx_page_views_created_at ON public.page_views (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_page_views_visitor_id ON public.page_views (visitor_id);
CREATE INDEX IF NOT EXISTS idx_page_views_session_id ON public.page_views (session_id);
CREATE INDEX IF NOT EXISTS idx_page_views_user_id    ON public.page_views (user_id);
CREATE INDEX IF NOT EXISTS idx_page_views_path       ON public.page_views (path);
CREATE INDEX IF NOT EXISTS idx_page_views_country    ON public.page_views (country);

-- Server-side auto-fill user_id from the JWT so clients cannot spoof identity.
CREATE OR REPLACE FUNCTION public.page_views_set_user_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF NEW.user_id IS NULL AND auth.uid() IS NOT NULL THEN
    NEW.user_id := auth.uid();
  ELSIF NEW.user_id IS NOT NULL AND auth.uid() IS NOT NULL AND NEW.user_id <> auth.uid() THEN
    -- Anti-spoof: if caller sent a user_id that doesn't match their JWT, override.
    NEW.user_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_page_views_set_user_id ON public.page_views;
CREATE TRIGGER trg_page_views_set_user_id
  BEFORE INSERT ON public.page_views
  FOR EACH ROW
  EXECUTE FUNCTION public.page_views_set_user_id();

-- RLS
ALTER TABLE public.page_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can insert page views" ON public.page_views;
CREATE POLICY "Anyone can insert page views"
  ON public.page_views
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Admins read page views" ON public.page_views;
CREATE POLICY "Admins read page views"
  ON public.page_views
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_id = auth.uid() AND is_admin = true
    )
  );

DROP POLICY IF EXISTS "Admins manage page views" ON public.page_views;
CREATE POLICY "Admins manage page views"
  ON public.page_views
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_id = auth.uid() AND is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_id = auth.uid() AND is_admin = true
    )
  );

GRANT INSERT ON public.page_views TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.page_views_id_seq TO anon, authenticated;
GRANT SELECT ON public.page_views TO authenticated;

---------------------------------------------------------------------
-- RPC: get_analytics_summary(p_days)
-- Returns a single jsonb blob with totals, daily/hourly series, top paths,
-- top views, top countries, cities, browsers, OS, device types, languages,
-- and referrer hosts. Admin-only.
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_analytics_summary(p_days integer DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_from timestamptz;
  v_to   timestamptz := now();
  v_days integer := GREATEST(1, LEAST(COALESCE(p_days, 7), 365));
  v_out  jsonb;
BEGIN
  -- Admin check
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE auth_id = v_uid AND is_admin = true
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_from := v_to - (v_days || ' days')::interval;

  WITH scoped AS (
    SELECT *
      FROM public.page_views
     WHERE created_at >= v_from
  ),
  totals AS (
    SELECT
      COUNT(*)::bigint                                   AS hits,
      COUNT(DISTINCT visitor_id)::bigint                 AS unique_visitors,
      COUNT(DISTINCT session_id)::bigint                 AS unique_sessions,
      COUNT(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)::bigint AS authed_visitors,
      COUNT(DISTINCT visitor_id) FILTER (WHERE user_id IS NULL)::bigint  AS anon_visitors,
      COUNT(DISTINCT country) FILTER (WHERE country IS NOT NULL)::bigint AS countries
    FROM scoped
  ),
  lifetime AS (
    SELECT
      COUNT(*)::bigint                     AS hits,
      COUNT(DISTINCT visitor_id)::bigint   AS visitors
    FROM public.page_views
  ),
  daily AS (
    SELECT
      to_char(date_trunc('day', created_at), 'YYYY-MM-DD') AS day,
      COUNT(*)::bigint AS hits,
      COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped
    GROUP BY 1
    ORDER BY 1 ASC
  ),
  hourly AS (
    SELECT
      EXTRACT(HOUR FROM created_at)::integer AS hour,
      COUNT(*)::bigint AS hits
    FROM scoped
    GROUP BY 1
    ORDER BY 1 ASC
  ),
  top_paths AS (
    SELECT path, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE path IS NOT NULL
    GROUP BY path ORDER BY hits DESC LIMIT 20
  ),
  top_views AS (
    SELECT view_name AS view, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE view_name IS NOT NULL AND view_name <> ''
    GROUP BY view_name ORDER BY hits DESC LIMIT 20
  ),
  top_countries AS (
    SELECT country, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE country IS NOT NULL
    GROUP BY country ORDER BY hits DESC LIMIT 20
  ),
  top_cities AS (
    SELECT city, country, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE city IS NOT NULL
    GROUP BY city, country ORDER BY hits DESC LIMIT 20
  ),
  top_browsers AS (
    SELECT browser, COUNT(*)::bigint AS hits
    FROM scoped WHERE browser IS NOT NULL
    GROUP BY browser ORDER BY hits DESC LIMIT 15
  ),
  top_os AS (
    SELECT os, COUNT(*)::bigint AS hits
    FROM scoped WHERE os IS NOT NULL
    GROUP BY os ORDER BY hits DESC LIMIT 15
  ),
  top_devices AS (
    SELECT device_type, COUNT(*)::bigint AS hits
    FROM scoped WHERE device_type IS NOT NULL
    GROUP BY device_type ORDER BY hits DESC LIMIT 10
  ),
  top_languages AS (
    SELECT split_part(COALESCE(language, ''), '-', 1) AS language, COUNT(*)::bigint AS hits
    FROM scoped WHERE language IS NOT NULL AND language <> ''
    GROUP BY 1 ORDER BY hits DESC LIMIT 15
  ),
  top_referrers AS (
    SELECT referrer_host, COUNT(*)::bigint AS hits
    FROM scoped WHERE referrer_host IS NOT NULL AND referrer_host <> ''
    GROUP BY referrer_host ORDER BY hits DESC LIMIT 15
  ),
  recent AS (
    SELECT created_at, visitor_id, user_id, view_name, path, country, city, browser, os, device_type
    FROM scoped
    ORDER BY created_at DESC
    LIMIT 50
  )
  SELECT jsonb_build_object(
    'range',     jsonb_build_object('days', v_days, 'from', v_from, 'to', v_to),
    'totals',    (SELECT to_jsonb(totals) FROM totals),
    'lifetime',  (SELECT to_jsonb(lifetime) FROM lifetime),
    'daily',     COALESCE((SELECT jsonb_agg(to_jsonb(daily)) FROM daily), '[]'::jsonb),
    'hourly',    COALESCE((SELECT jsonb_agg(to_jsonb(hourly)) FROM hourly), '[]'::jsonb),
    'top_paths', COALESCE((SELECT jsonb_agg(to_jsonb(top_paths)) FROM top_paths), '[]'::jsonb),
    'top_views', COALESCE((SELECT jsonb_agg(to_jsonb(top_views)) FROM top_views), '[]'::jsonb),
    'countries', COALESCE((SELECT jsonb_agg(to_jsonb(top_countries)) FROM top_countries), '[]'::jsonb),
    'cities',    COALESCE((SELECT jsonb_agg(to_jsonb(top_cities)) FROM top_cities), '[]'::jsonb),
    'browsers',  COALESCE((SELECT jsonb_agg(to_jsonb(top_browsers)) FROM top_browsers), '[]'::jsonb),
    'os',        COALESCE((SELECT jsonb_agg(to_jsonb(top_os)) FROM top_os), '[]'::jsonb),
    'devices',   COALESCE((SELECT jsonb_agg(to_jsonb(top_devices)) FROM top_devices), '[]'::jsonb),
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(top_languages)) FROM top_languages), '[]'::jsonb),
    'referrers', COALESCE((SELECT jsonb_agg(to_jsonb(top_referrers)) FROM top_referrers), '[]'::jsonb),
    'recent',    COALESCE((SELECT jsonb_agg(to_jsonb(recent)) FROM recent), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_analytics_summary(integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_analytics_summary(integer) FROM anon, public;

COMMIT;

NOTIFY pgrst, 'reload schema';
