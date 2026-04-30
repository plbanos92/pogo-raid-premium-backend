-- Widen event_type CHECK to include 'state' (store state-change tracking)
-- and 'realtime_debug' (already used in frontend but missing from constraint).
ALTER TABLE public.session_events
  DROP CONSTRAINT IF EXISTS chk_event_type;

ALTER TABLE public.session_events
  ADD CONSTRAINT chk_event_type CHECK (
    event_type IN (
      'session', 'nav', 'queue', 'host', 'account',
      'lifecycle', 'realtime', 'realtime_debug',
      'data', 'error', 'ui', 'admin', 'state'
    )
  );
