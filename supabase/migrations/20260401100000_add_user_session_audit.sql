-- Phase N: User Session Audit Trail
-- Adds user_sessions + session_events tables, RLS policies, and four RPCs for
-- client-side session instrumentation. Additive only — no existing tables modified.

-- =============================================================================
-- 1. TABLES
-- =============================================================================

CREATE TABLE public.user_sessions (
  id           uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id      uuid NOT NULL,
  session_date date NOT NULL DEFAULT CURRENT_DATE,
  started_at   timestamptz NOT NULL DEFAULT now(),
  ended_at     timestamptz,
  end_reason   text CHECK (end_reason IN ('sign_out', 'session_expiry', 'page_close')),
  user_agent   text,
  client_info  jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX idx_user_sessions_user_date ON public.user_sessions (user_id, session_date DESC);
CREATE INDEX idx_user_sessions_started   ON public.user_sessions (started_at DESC);

CREATE TABLE public.session_events (
  id             uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id     uuid NOT NULL REFERENCES public.user_sessions(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL,
  seq            int NOT NULL,
  event_type     text NOT NULL,
  event_name     text NOT NULL,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  store_snapshot jsonb,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_event_type CHECK (
    event_type IN ('session','nav','queue','host','account','lifecycle','realtime','data','error')
  )
);

-- Idempotent flush: duplicate (session_id, seq) is silently skipped via ON CONFLICT
ALTER TABLE public.session_events
  ADD CONSTRAINT uq_session_event_seq UNIQUE (session_id, seq);

CREATE INDEX idx_session_events_user_time    ON public.session_events (user_id, occurred_at DESC);
CREATE INDEX idx_session_events_event_type   ON public.session_events (event_type, event_name);

-- =============================================================================
-- 2. RLS
-- =============================================================================

-- user_sessions
ALTER TABLE public.user_sessions ENABLE ROW LEVEL SECURITY;

-- Owner: SELECT + INSERT only. No UPDATE or DELETE — audit rows are immutable.
-- UPDATE handled exclusively by close_user_session SECURITY DEFINER RPC.
-- No UPDATE policy prevents direct REST PATCH tampering of started_at/user_agent/client_info.
CREATE POLICY "Own sessions: select"
  ON public.user_sessions FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Own sessions: insert"
  ON public.user_sessions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- session_events
ALTER TABLE public.session_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Own events: select"
  ON public.session_events FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Own events: insert"
  ON public.session_events FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND session_id IN (
      SELECT id FROM public.user_sessions WHERE user_id = auth.uid()
    )
  );

-- No UPDATE or DELETE on either table for any user role.
-- Admin reads handled via service_role (Supabase Studio / CLI) or get_session_replay RPC.

-- =============================================================================
-- 3. RPCs
-- =============================================================================

-- open_user_session
-- Creates a session row and returns the new session UUID.
-- Called by frontend immediately after successful sign-in.
CREATE OR REPLACE FUNCTION public.open_user_session(
  p_user_agent  text    DEFAULT NULL,
  p_client_info jsonb   DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_session_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_sessions (user_id, user_agent, client_info)
  VALUES (v_uid, p_user_agent, COALESCE(p_client_info, '{}'::jsonb))
  RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.open_user_session(text, jsonb) TO authenticated;

-- close_user_session
-- Sets ended_at + end_reason and optionally flushes a final batch of events.
CREATE OR REPLACE FUNCTION public.close_user_session(
  p_session_id  uuid,
  p_reason      text,
  p_final_events jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  evt   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Validate ownership
  IF NOT EXISTS (
    SELECT 1 FROM public.user_sessions
    WHERE id = p_session_id AND user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Session not found or access denied' USING ERRCODE = '42501';
  END IF;

  -- Flush final events (same logic as batch_insert_session_events)
  IF p_final_events IS NOT NULL AND jsonb_array_length(p_final_events) > 0 THEN
    FOR evt IN SELECT * FROM jsonb_array_elements(p_final_events) LOOP
      INSERT INTO public.session_events (
        session_id, user_id, seq, event_type, event_name,
        payload, store_snapshot, occurred_at
      ) VALUES (
        p_session_id,
        v_uid,
        (evt->>'seq')::int,
        evt->>'event_type',
        evt->>'event_name',
        COALESCE(evt->'payload', '{}'::jsonb),
        evt->'store_snapshot',
        COALESCE((evt->>'occurred_at')::timestamptz, now())
      )
      ON CONFLICT (session_id, seq) DO NOTHING;
    END LOOP;
  END IF;

  -- Close the session
  UPDATE public.user_sessions
  SET ended_at   = now(),
      end_reason = p_reason
  WHERE id = p_session_id AND user_id = v_uid
    AND ended_at IS NULL;
END;
$$;
GRANT EXECUTE ON FUNCTION public.close_user_session(uuid, text, jsonb) TO authenticated;

-- batch_insert_session_events
-- Main write path: frontend flushes buffered events on a 5s timer or on buffer-full.
-- INSERT ON CONFLICT DO NOTHING: duplicate seq within same session is silently skipped.
CREATE OR REPLACE FUNCTION public.batch_insert_session_events(
  p_session_id uuid,
  p_events     jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  evt   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Validate ownership to prevent session ID spoofing
  IF NOT EXISTS (
    SELECT 1 FROM public.user_sessions
    WHERE id = p_session_id AND user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Session not found or access denied' USING ERRCODE = '42501';
  END IF;

  IF p_events IS NULL OR jsonb_array_length(p_events) = 0 THEN
    RETURN;
  END IF;

  FOR evt IN SELECT * FROM jsonb_array_elements(p_events) LOOP
    INSERT INTO public.session_events (
      session_id, user_id, seq, event_type, event_name,
      payload, store_snapshot, occurred_at
    ) VALUES (
      p_session_id,
      v_uid,
      (evt->>'seq')::int,
      evt->>'event_type',
      evt->>'event_name',
      COALESCE(evt->'payload', '{}'::jsonb),
      evt->'store_snapshot',
      COALESCE((evt->>'occurred_at')::timestamptz, now())
    )
    ON CONFLICT (session_id, seq) DO NOTHING;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public.batch_insert_session_events(uuid, jsonb) TO authenticated;

-- get_session_replay
-- Admin-only. Returns complete ordered timeline for a session.
-- Accessible by session owner, admin (is_admin = true on user_profiles), or service_role.
CREATE OR REPLACE FUNCTION public.get_session_replay(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_session    jsonb;
  v_profile    jsonb;
  v_events     jsonb;
  v_trans      jsonb;
  v_window_end timestamptz;
BEGIN
  -- Allow: session owner OR admin OR service_role (auth.uid() = NULL)
  IF v_uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.user_sessions
      WHERE id = p_session_id AND user_id = v_uid
    ) THEN
      -- Check if user is admin
      IF NOT EXISTS (
        SELECT 1 FROM public.user_profiles
        WHERE auth_id = v_uid AND is_admin = true
      ) THEN
        RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;

  -- Session metadata
  SELECT to_jsonb(s) INTO v_session
  FROM public.user_sessions s
  WHERE s.id = p_session_id;

  IF v_session IS NULL THEN
    RETURN jsonb_build_object('error', 'session not found');
  END IF;

  v_window_end := COALESCE(
    (v_session->>'ended_at')::timestamptz,
    now()
  );

  -- User profile at time of session
  SELECT jsonb_build_object(
    'display_name',   up.display_name,
    'in_game_name',   up.in_game_name,
    'friend_code',    up.friend_code,
    'email',          au.email,
    'trainer_level',  up.trainer_level,
    'team',           up.team
  ) INTO v_profile
  FROM public.user_sessions us
  JOIN public.user_profiles up ON up.auth_id = us.user_id
  JOIN auth.users au ON au.id = us.user_id
  WHERE us.id = p_session_id;

  -- Client events in sequence order
  SELECT jsonb_agg(
    jsonb_build_object(
      'seq',            se.seq,
      'event_type',     se.event_type,
      'event_name',     se.event_name,
      'payload',        se.payload,
      'store_snapshot', se.store_snapshot,
      'occurred_at',    se.occurred_at
    )
    ORDER BY se.seq
  ) INTO v_events
  FROM public.session_events se
  WHERE se.session_id = p_session_id;

  -- Server-side state transitions within session window
  SELECT jsonb_agg(
    jsonb_build_object(
      'raid_id',         rst.raid_id,
      'queue_entry_id',  rst.queue_entry_id,
      'actor_user_id',   rst.actor_user_id,
      'from_state',      rst.from_state,
      'to_state',        rst.to_state,
      'transitioned_at', rst.transitioned_at,
      'action_source',   rst.action_source
    )
    ORDER BY rst.transitioned_at
  ) INTO v_trans
  FROM public.raid_state_transitions rst
  WHERE rst.transitioned_at BETWEEN (v_session->>'started_at')::timestamptz AND v_window_end
    AND (
      rst.actor_user_id = (v_session->>'user_id')::uuid
      OR rst.raid_id IN (
        SELECT DISTINCT raid_id FROM public.raid_queues
        WHERE user_id = (v_session->>'user_id')::uuid
      )
    );

  RETURN jsonb_build_object(
    'session',           v_session,
    'profile',           v_profile,
    'events',            COALESCE(v_events, '[]'::jsonb),
    'state_transitions', COALESCE(v_trans, '[]'::jsonb)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_session_replay(uuid) TO authenticated;
