-- Widen event_type CHECK to include 'ui' (global click interceptor) and 'admin' (future admin semantic events)
ALTER TABLE public.session_events
  DROP CONSTRAINT IF EXISTS chk_event_type;

ALTER TABLE public.session_events
  ADD CONSTRAINT chk_event_type CHECK (
    event_type IN (
      'session', 'nav', 'queue', 'host', 'account',
      'lifecycle', 'realtime', 'data', 'error',
      'ui', 'admin'
    )
  );
