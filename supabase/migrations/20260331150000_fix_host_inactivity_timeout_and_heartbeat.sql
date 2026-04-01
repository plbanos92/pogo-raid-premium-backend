-- Phase 1 bugfix: make check_host_inactivity read timeout from app_config
-- instead of hardcoded 100s, and add touch_host_activity heartbeat RPC.

--------------------------------------------------------------------------------
-- 1. Rewrite check_host_inactivity — configurable timeout
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_host_inactivity(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid public.raids%ROWTYPE;
  v_timeout int;
  v_lobby_size int;
  v_new_raid_id uuid;
  v_entry record;
BEGIN
  SELECT * INTO v_raid FROM public.raids WHERE id = p_raid_id AND is_active = true;
  IF NOT FOUND THEN RETURN false; END IF;

  -- Read configurable timeout (seconds) from app_config
  SELECT host_inactivity_seconds INTO v_timeout FROM public.app_config WHERE id = 1;

  -- Check: has host been inactive longer than the configured timeout?
  IF v_raid.last_host_action_at >= now() - (v_timeout * interval '1 second') THEN
    RETURN false;
  END IF;

  -- Check: is lobby full?
  SELECT COUNT(*) INTO v_lobby_size
  FROM public.raid_queues WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');
  IF v_lobby_size < v_raid.capacity THEN RETURN false; END IF;

  -- Destroy the raid
  UPDATE public.raids SET is_active = false WHERE id = p_raid_id;

  -- Find best alternative raid for same boss
  SELECT r.id INTO v_new_raid_id
  FROM public.raids r
  WHERE r.raid_boss_id = v_raid.raid_boss_id
    AND r.is_active = true
    AND r.id <> p_raid_id
    AND (SELECT COUNT(*) FROM public.raid_queues q
         WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) < r.capacity
  ORDER BY (SELECT COUNT(*) FROM public.raid_queues q
            WHERE q.raid_id = r.id AND q.status IN ('queued','invited','confirmed')) DESC
  LIMIT 1;

  -- Re-queue each affected user (with priority boost)
  FOR v_entry IN
    SELECT user_id, note FROM public.raid_queues
    WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed')
  LOOP
    IF v_new_raid_id IS NOT NULL THEN
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (v_new_raid_id, v_entry.user_id, 'queued', true,
              'Re-queued (host inactivity) — priority restored')
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END IF;
  END LOOP;

  -- Cancel original entries
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');

  -- Recompute positions in new raid if users were added
  IF v_new_raid_id IS NOT NULL THEN
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_host_inactivity(uuid) TO authenticated;

--------------------------------------------------------------------------------
-- 2. New RPC: touch_host_activity (heartbeat)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_host_activity(p_raid_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.raids
    SET last_host_action_at = now()
    WHERE id = p_raid_id
      AND host_user_id = auth.uid()
      AND is_active = true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.touch_host_activity(uuid) TO authenticated;
