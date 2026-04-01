-- Tighten realtime session TTL from 10 minutes → 3 minutes.
-- Heartbeat interval on the client is 1.5 minutes, giving a 2× safety margin.
-- Faster TTL means a crashed/backgrounded user's slot is reclaimed within ~3 minutes
-- instead of ~10, so the slot count stays accurate sooner.

CREATE OR REPLACE FUNCTION public.get_realtime_slot_stats()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_used  int;
  v_total int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  -- Purge sessions idle for > 3 minutes (no heartbeat = abandoned tab/crash)
  DELETE FROM public.realtime_sessions
  WHERE granted_at < now() - interval '3 minutes';
  SELECT COUNT(*) INTO v_used FROM public.realtime_sessions;
  SELECT realtime_slots INTO v_total FROM public.app_config WHERE id = 1;
  RETURN jsonb_build_object('used', v_used, 'total', v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_realtime_slot_stats() TO authenticated;
