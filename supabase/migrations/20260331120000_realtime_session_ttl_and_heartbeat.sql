-- Fix: purge abandoned realtime_sessions inside get_realtime_slot_stats.
--
-- Root cause: beforeunload fetch (keepalive:true) is best-effort — it fails silently
-- on browser crash, iOS Safari page kill, Android Chrome backgrounding, and network
-- drops. Orphaned rows accumulate and inflate the slot count indefinitely.
--
-- Strategy:
--   • Client heartbeats every 4 minutes via claimRealtimeSlot() (idempotent, refreshes
--     granted_at). This proves the session is alive.
--   • get_realtime_slot_stats() purges rows not refreshed in > 10 minutes before
--     counting. Called every 5 s by _slotStatsPollTimer — cleanup is self-healing.
--     The 10-min TTL gives a 2.5× safety margin over the 4-min heartbeat.
--   • The existing index idx_realtime_sessions_vip_granted covers the range scan,
--     so the DELETE on 0 rows (steady state) is cheap.

CREATE OR REPLACE FUNCTION public.get_realtime_slot_stats()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_used  int;
  v_total int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  -- Purge sessions idle for > 10 minutes (no heartbeat = abandoned tab/crash)
  DELETE FROM public.realtime_sessions
  WHERE granted_at < now() - interval '10 minutes';
  SELECT COUNT(*) INTO v_used FROM public.realtime_sessions;
  SELECT realtime_slots INTO v_total FROM public.app_config WHERE id = 1;
  RETURN jsonb_build_object('used', v_used, 'total', v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_realtime_slot_stats() TO authenticated;
