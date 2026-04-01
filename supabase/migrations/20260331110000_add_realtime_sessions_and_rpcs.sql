-- Part A — realtime_sessions table + RLS
CREATE TABLE IF NOT EXISTS public.realtime_sessions (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  is_vip     boolean     NOT NULL DEFAULT false,
  granted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id)
);
CREATE INDEX IF NOT EXISTS idx_realtime_sessions_vip_granted
  ON public.realtime_sessions (is_vip, granted_at);
ALTER TABLE public.realtime_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "realtime_sessions_select_own" ON public.realtime_sessions
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "realtime_sessions_delete_own" ON public.realtime_sessions
  FOR DELETE USING (user_id = auth.uid());
GRANT SELECT, DELETE ON TABLE public.realtime_sessions TO authenticated;

-- Part B — claim_realtime_slot RPC
CREATE OR REPLACE FUNCTION public.claim_realtime_slot()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid       uuid    := auth.uid();
  v_is_vip    boolean;
  v_max_slots int;
  v_active    int;
  v_evict_uid uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT EXISTS(
    SELECT 1 FROM public.subscriptions
    WHERE user_id = v_uid AND is_vip = true AND status = 'active'
  ) INTO v_is_vip;
  SELECT realtime_slots INTO v_max_slots FROM public.app_config WHERE id = 1;
  -- Global kill switch: realtime_slots = 0 disables everyone including VIPs
  IF v_max_slots = 0 THEN
    RETURN jsonb_build_object('granted', false, 'mode', 'polling');
  END IF;
  -- Idempotency: already holds a slot → refresh timestamp
  IF EXISTS (SELECT 1 FROM public.realtime_sessions WHERE user_id = v_uid) THEN
    UPDATE public.realtime_sessions
    SET is_vip = v_is_vip, granted_at = now()
    WHERE user_id = v_uid;
    RETURN jsonb_build_object('granted', true, 'mode', 'realtime');
  END IF;
  -- VIPs are always granted when realtime is enabled (realtime_slots > 0)
  IF v_is_vip THEN
    SELECT COUNT(*) INTO v_active FROM public.realtime_sessions;
    -- If pool is at capacity, try to evict the oldest free-tier session to make room
    IF v_active >= v_max_slots THEN
      SELECT user_id INTO v_evict_uid
        FROM public.realtime_sessions
        WHERE is_vip = false
        ORDER BY granted_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED;
      IF v_evict_uid IS NOT NULL THEN
        DELETE FROM public.realtime_sessions WHERE user_id = v_evict_uid;
      END IF;
      -- VIP is granted even if no free-tier session was available to evict
    END IF;
    INSERT INTO public.realtime_sessions (user_id, is_vip) VALUES (v_uid, true);
    RETURN jsonb_build_object('granted', true, 'mode', 'realtime');
  END IF;
  -- Free-tier: only granted when pool has capacity
  SELECT COUNT(*) INTO v_active FROM public.realtime_sessions;
  IF v_active < v_max_slots THEN
    INSERT INTO public.realtime_sessions (user_id, is_vip) VALUES (v_uid, false);
    RETURN jsonb_build_object('granted', true, 'mode', 'realtime');
  END IF;
  RETURN jsonb_build_object('granted', false, 'mode', 'polling');
END;
$$;
GRANT EXECUTE ON FUNCTION public.claim_realtime_slot() TO authenticated;

-- Part C — release_realtime_slot RPC
CREATE OR REPLACE FUNCTION public.release_realtime_slot()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.realtime_sessions WHERE user_id = auth.uid();
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_realtime_slot() TO authenticated;

-- Part D — admin_update_realtime_slots RPC
CREATE OR REPLACE FUNCTION public.admin_update_realtime_slots(p_slots int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM public.user_profiles
    WHERE auth_id = auth.uid() AND is_admin = true
  ) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF p_slots < 0 THEN RAISE EXCEPTION 'realtime_slots must be >= 0'; END IF;
  UPDATE public.app_config
  SET realtime_slots = p_slots, updated_at = now()
  WHERE id = 1;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_update_realtime_slots(int) TO authenticated;

-- Part E — get_realtime_slot_stats RPC (Phase 1 Amendment — included directly since Migration 2 is not yet applied)
-- get_realtime_slot_stats: returns current used + total slots for all authenticated users.
-- SECURITY DEFINER is required to bypass the realtime_sessions RLS policy
-- (SELECT USING user_id = auth.uid()), which would otherwise limit COUNT(*) to 0 or 1.
CREATE OR REPLACE FUNCTION public.get_realtime_slot_stats()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_used  int;
  v_total int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT COUNT(*) INTO v_used FROM public.realtime_sessions;
  SELECT realtime_slots INTO v_total FROM public.app_config WHERE id = 1;
  RETURN jsonb_build_object('used', v_used, 'total', v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_realtime_slot_stats() TO authenticated;
