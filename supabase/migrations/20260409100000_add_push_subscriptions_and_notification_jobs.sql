-- Phase 2: Add backend data model for push subscriptions and notification jobs.
-- Creates push_subscriptions and notification_jobs tables with RLS and RPCs.

-- ---------------------------------------------------------------------------
-- Table: push_subscriptions
-- Stores Web Push API subscription objects for each user device/browser.
-- ---------------------------------------------------------------------------

CREATE TABLE public.push_subscriptions (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint      text        NOT NULL,
  p256dh        text        NOT NULL,
  auth          text        NOT NULL,
  device_label  text        NULL,
  platform      text        NULL,
  user_agent    text        NULL,
  app_mode      text        NULL,       -- 'browser' | 'pwa'
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NULL,
  disabled_at   timestamptz NULL,
  CONSTRAINT uq_push_subscriptions_endpoint UNIQUE (endpoint)
);

-- Index: active subscriptions per user (service-role sender uses this)
CREATE INDEX idx_push_subscriptions_user_disabled
  ON public.push_subscriptions (user_id, disabled_at);

-- RLS
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users select own push subscriptions"
  ON public.push_subscriptions
  FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "Users insert own push subscriptions"
  ON public.push_subscriptions
  FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users update own push subscriptions"
  ON public.push_subscriptions
  FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "Users delete own push subscriptions"
  ON public.push_subscriptions
  FOR DELETE
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Table: notification_jobs
-- Durable queue of push notification payloads to be dispatched by the Edge
-- Function. Users may read their own rows for diagnostics; only service_role
-- may write (via privileged RPCs or the dispatcher function).
-- ---------------------------------------------------------------------------

CREATE TABLE public.notification_jobs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type    text        NOT NULL,
  title         text        NOT NULL,
  body          text        NOT NULL,
  payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key    text        NULL,
  status        text        NOT NULL DEFAULT 'pending',  -- pending | sent | failed | discarded
  attempt_count int         NOT NULL DEFAULT 0,
  last_error    text        NULL,
  scheduled_at  timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz NULL
);

-- Index: dispatcher scans pending jobs ordered by scheduled_at
CREATE INDEX idx_notification_jobs_status_scheduled
  ON public.notification_jobs (status, scheduled_at);

-- Unique partial index backing ON CONFLICT (dedupe_key) DO NOTHING in Phase 3
CREATE UNIQUE INDEX uq_notification_jobs_dedupe_key
  ON public.notification_jobs (dedupe_key)
  WHERE dedupe_key IS NOT NULL;

-- RLS
ALTER TABLE public.notification_jobs ENABLE ROW LEVEL SECURITY;

-- Users may read their own jobs for diagnostics only; no user-side mutations.
CREATE POLICY "Users select own notification jobs"
  ON public.notification_jobs
  FOR SELECT
  USING (user_id = auth.uid());

-- No INSERT / UPDATE / DELETE policies for the authenticated role.
-- service_role bypasses RLS and writes rows directly (dispatcher + enqueue helpers).

-- ---------------------------------------------------------------------------
-- RPC: upsert_push_subscription
-- Allows an authenticated user to register or refresh a push subscription.
-- Uses endpoint as the conflict key so re-subscribing the same browser
-- updates keys and marks the subscription as active (clears disabled_at).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.upsert_push_subscription(
  p_endpoint     text,
  p_p256dh       text,
  p_auth         text,
  p_device_label text DEFAULT NULL,
  p_platform     text DEFAULT NULL,
  p_user_agent   text DEFAULT NULL,
  p_app_mode     text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id  uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.push_subscriptions (
    user_id, endpoint, p256dh, auth,
    device_label, platform, user_agent, app_mode,
    updated_at, last_seen_at, disabled_at
  )
  VALUES (
    v_uid, p_endpoint, p_p256dh, p_auth,
    p_device_label, p_platform, p_user_agent, p_app_mode,
    now(), now(), NULL
  )
  ON CONFLICT (endpoint) DO UPDATE SET
    p256dh       = EXCLUDED.p256dh,
    auth         = EXCLUDED.auth,
    device_label = EXCLUDED.device_label,
    platform     = EXCLUDED.platform,
    user_agent   = EXCLUDED.user_agent,
    app_mode     = EXCLUDED.app_mode,
    updated_at   = now(),
    last_seen_at = now(),
    disabled_at  = NULL
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_push_subscription(
  text, text, text, text, text, text, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- RPC: delete_push_subscription
-- Allows an authenticated user to remove one of their push subscriptions
-- (e.g. when the user explicitly opts out or the endpoint is known-expired).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_push_subscription(
  p_endpoint text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_deleted  boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.push_subscriptions
  WHERE endpoint = p_endpoint
    AND user_id  = v_uid;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_push_subscription(text) TO authenticated;
