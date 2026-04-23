-- Migration: Extend page_views with behavior + richer device/network signals.
-- Adds session counters, UTM params, performance timings, UA client hints,
-- visibility/focus state, and server-side CF extras (postal/lat/lng, protocol,
-- TLS, timezone). All new columns are nullable so this is a no-op for existing
-- clients/rows.
--
-- Also replaces get_analytics_summary() to expose the most useful new
-- aggregates (UTM sources/mediums/campaigns, navigation types, entry paths,
-- orientations, bot/webdriver counts, and median-ish performance stats).

BEGIN;

-- ── Behavior / session fields ───────────────────────────────────────────────
ALTER TABLE public.page_views
  ADD COLUMN IF NOT EXISTS visitor_hit_num        bigint,
  ADD COLUMN IF NOT EXISTS session_hit_num        integer,
  ADD COLUMN IF NOT EXISTS is_new_visitor         boolean,
  ADD COLUMN IF NOT EXISTS is_new_session         boolean,
  ADD COLUMN IF NOT EXISTS prev_view              text,
  ADD COLUMN IF NOT EXISTS prev_path              text,
  ADD COLUMN IF NOT EXISTS time_on_prev_view_ms   bigint,
  ADD COLUMN IF NOT EXISTS session_entry_path     text,
  ADD COLUMN IF NOT EXISTS session_entry_referrer text,
  ADD COLUMN IF NOT EXISTS session_started_at     timestamptz,
  ADD COLUMN IF NOT EXISTS utm_source             text,
  ADD COLUMN IF NOT EXISTS utm_medium             text,
  ADD COLUMN IF NOT EXISTS utm_campaign           text,
  ADD COLUMN IF NOT EXISTS utm_term               text,
  ADD COLUMN IF NOT EXISTS utm_content            text,
  ADD COLUMN IF NOT EXISTS url_query              text,
  ADD COLUMN IF NOT EXISTS url_hash               text;

-- ── Device / environment fields ────────────────────────────────────────────
ALTER TABLE public.page_views
  ADD COLUMN IF NOT EXISTS orientation            text,
  ADD COLUMN IF NOT EXISTS is_online              boolean,
  ADD COLUMN IF NOT EXISTS cookie_enabled         boolean,
  ADD COLUMN IF NOT EXISTS webdriver              boolean,
  ADD COLUMN IF NOT EXISTS save_data              boolean,
  ADD COLUMN IF NOT EXISTS rtt                    integer,
  ADD COLUMN IF NOT EXISTS ua_mobile              boolean,
  ADD COLUMN IF NOT EXISTS ua_platform            text,
  ADD COLUMN IF NOT EXISTS visibility_state       text,
  ADD COLUMN IF NOT EXISTS has_focus              boolean,
  ADD COLUMN IF NOT EXISTS nav_type               text,
  ADD COLUMN IF NOT EXISTS page_load_ms           integer,
  ADD COLUMN IF NOT EXISTS dcl_ms                 integer,
  ADD COLUMN IF NOT EXISTS fp_ms                  integer,
  ADD COLUMN IF NOT EXISTS fcp_ms                 integer;

-- ── Server-side CF enrichment extras ───────────────────────────────────────
ALTER TABLE public.page_views
  ADD COLUMN IF NOT EXISTS cf_postal_code         text,
  ADD COLUMN IF NOT EXISTS cf_latitude            numeric(8,5),
  ADD COLUMN IF NOT EXISTS cf_longitude           numeric(9,5),
  ADD COLUMN IF NOT EXISTS cf_timezone            text,
  ADD COLUMN IF NOT EXISTS cf_region_code         text,
  ADD COLUMN IF NOT EXISTS cf_metro_code          text,
  ADD COLUMN IF NOT EXISTS cf_http_protocol       text,
  ADD COLUMN IF NOT EXISTS cf_tls_version         text;

CREATE INDEX IF NOT EXISTS idx_page_views_utm_source
  ON public.page_views (utm_source) WHERE utm_source IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_page_views_utm_campaign
  ON public.page_views (utm_campaign) WHERE utm_campaign IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_page_views_is_new_session
  ON public.page_views (is_new_session) WHERE is_new_session = true;
CREATE INDEX IF NOT EXISTS idx_page_views_webdriver
  ON public.page_views (webdriver) WHERE webdriver = true;

---------------------------------------------------------------------
-- RPC: get_analytics_summary(p_days)  — extended output
-- Backward compatible — all previously-returned keys are still present.
-- Adds: utm_sources / utm_mediums / utm_campaigns / nav_types / entry_paths
--       orientations / performance / bots
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
      COUNT(*)::bigint                                                   AS hits,
      COUNT(DISTINCT visitor_id)::bigint                                 AS unique_visitors,
      COUNT(DISTINCT session_id)::bigint                                 AS unique_sessions,
      COUNT(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)::bigint AS authed_visitors,
      COUNT(DISTINCT visitor_id) FILTER (WHERE user_id IS NULL)::bigint  AS anon_visitors,
      COUNT(DISTINCT country) FILTER (WHERE country IS NOT NULL)::bigint AS countries,
      COUNT(*) FILTER (WHERE is_new_session = true)::bigint              AS new_sessions,
      COUNT(*) FILTER (WHERE is_new_visitor = true)::bigint              AS new_visitors,
      COUNT(*) FILTER (WHERE webdriver = true)::bigint                   AS bot_hits,
      COUNT(*) FILTER (WHERE is_standalone = true)::bigint               AS pwa_hits
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
  utm_sources AS (
    SELECT utm_source AS source, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE utm_source IS NOT NULL AND utm_source <> ''
    GROUP BY utm_source ORDER BY hits DESC LIMIT 15
  ),
  utm_mediums AS (
    SELECT utm_medium AS medium, COUNT(*)::bigint AS hits
    FROM scoped WHERE utm_medium IS NOT NULL AND utm_medium <> ''
    GROUP BY utm_medium ORDER BY hits DESC LIMIT 10
  ),
  utm_campaigns AS (
    SELECT utm_campaign AS campaign, COUNT(*)::bigint AS hits, COUNT(DISTINCT visitor_id)::bigint AS visitors
    FROM scoped WHERE utm_campaign IS NOT NULL AND utm_campaign <> ''
    GROUP BY utm_campaign ORDER BY hits DESC LIMIT 15
  ),
  nav_types AS (
    SELECT nav_type, COUNT(*)::bigint AS hits
    FROM scoped WHERE nav_type IS NOT NULL AND nav_type <> ''
    GROUP BY nav_type ORDER BY hits DESC LIMIT 10
  ),
  entry_paths AS (
    SELECT session_entry_path AS path, COUNT(*)::bigint AS sessions
    FROM scoped
    WHERE session_entry_path IS NOT NULL AND session_entry_path <> ''
      AND is_new_session = true
    GROUP BY session_entry_path ORDER BY sessions DESC LIMIT 15
  ),
  orientations AS (
    SELECT orientation, COUNT(*)::bigint AS hits
    FROM scoped WHERE orientation IS NOT NULL AND orientation <> ''
    GROUP BY orientation ORDER BY hits DESC LIMIT 8
  ),
  effective_types AS (
    SELECT effective_type, COUNT(*)::bigint AS hits
    FROM scoped WHERE effective_type IS NOT NULL AND effective_type <> ''
    GROUP BY effective_type ORDER BY hits DESC LIMIT 8
  ),
  perf AS (
    SELECT
      ROUND(AVG(page_load_ms)::numeric, 0)::integer                             AS avg_page_load_ms,
      PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY page_load_ms)::integer       AS p50_page_load_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY page_load_ms)::integer       AS p95_page_load_ms,
      PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY fcp_ms)::integer             AS p50_fcp_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY fcp_ms)::integer             AS p95_fcp_ms,
      COUNT(*) FILTER (WHERE page_load_ms IS NOT NULL)::bigint                   AS samples
    FROM scoped
    WHERE page_load_ms IS NOT NULL AND page_load_ms > 0 AND page_load_ms < 120000
  ),
  recent AS (
    SELECT created_at, visitor_id, user_id, view_name, path, country, city,
           browser, os, device_type, utm_source, webdriver, is_new_session
    FROM scoped
    ORDER BY created_at DESC
    LIMIT 50
  )
  SELECT jsonb_build_object(
    'range',          jsonb_build_object('days', v_days, 'from', v_from, 'to', v_to),
    'totals',         (SELECT to_jsonb(totals) FROM totals),
    'lifetime',       (SELECT to_jsonb(lifetime) FROM lifetime),
    'daily',          COALESCE((SELECT jsonb_agg(to_jsonb(daily)) FROM daily), '[]'::jsonb),
    'hourly',         COALESCE((SELECT jsonb_agg(to_jsonb(hourly)) FROM hourly), '[]'::jsonb),
    'top_paths',      COALESCE((SELECT jsonb_agg(to_jsonb(top_paths)) FROM top_paths), '[]'::jsonb),
    'top_views',      COALESCE((SELECT jsonb_agg(to_jsonb(top_views)) FROM top_views), '[]'::jsonb),
    'countries',      COALESCE((SELECT jsonb_agg(to_jsonb(top_countries)) FROM top_countries), '[]'::jsonb),
    'cities',         COALESCE((SELECT jsonb_agg(to_jsonb(top_cities)) FROM top_cities), '[]'::jsonb),
    'browsers',       COALESCE((SELECT jsonb_agg(to_jsonb(top_browsers)) FROM top_browsers), '[]'::jsonb),
    'os',             COALESCE((SELECT jsonb_agg(to_jsonb(top_os)) FROM top_os), '[]'::jsonb),
    'devices',        COALESCE((SELECT jsonb_agg(to_jsonb(top_devices)) FROM top_devices), '[]'::jsonb),
    'languages',      COALESCE((SELECT jsonb_agg(to_jsonb(top_languages)) FROM top_languages), '[]'::jsonb),
    'referrers',      COALESCE((SELECT jsonb_agg(to_jsonb(top_referrers)) FROM top_referrers), '[]'::jsonb),
    'utm_sources',    COALESCE((SELECT jsonb_agg(to_jsonb(utm_sources)) FROM utm_sources), '[]'::jsonb),
    'utm_mediums',    COALESCE((SELECT jsonb_agg(to_jsonb(utm_mediums)) FROM utm_mediums), '[]'::jsonb),
    'utm_campaigns',  COALESCE((SELECT jsonb_agg(to_jsonb(utm_campaigns)) FROM utm_campaigns), '[]'::jsonb),
    'nav_types',      COALESCE((SELECT jsonb_agg(to_jsonb(nav_types)) FROM nav_types), '[]'::jsonb),
    'entry_paths',    COALESCE((SELECT jsonb_agg(to_jsonb(entry_paths)) FROM entry_paths), '[]'::jsonb),
    'orientations',   COALESCE((SELECT jsonb_agg(to_jsonb(orientations)) FROM orientations), '[]'::jsonb),
    'effective_types',COALESCE((SELECT jsonb_agg(to_jsonb(effective_types)) FROM effective_types), '[]'::jsonb),
    'perf',           (SELECT to_jsonb(perf) FROM perf),
    'recent',         COALESCE((SELECT jsonb_agg(to_jsonb(recent)) FROM recent), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_analytics_summary(integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_analytics_summary(integer) FROM anon, public;

COMMIT;

NOTIFY pgrst, 'reload schema';
