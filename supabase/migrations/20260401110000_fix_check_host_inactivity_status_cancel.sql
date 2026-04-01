-- Fix: check_host_inactivity was missing status='cancelled' update after
-- the relax_host_inactivity_guard revision (20260331160000).
-- Restores the dual-write behavior (is_active=false + status='cancelled')
-- that was present in 20260329210000 but accidentally dropped in later rewrites.

CREATE OR REPLACE FUNCTION public.check_host_inactivity(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_raid public.raids%ROWTYPE;
  v_timeout int;
  v_confirmed_count int;
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

  -- Guard: only fire if at least one player has confirmed (sent friend request).
  -- If no one is confirmed, there's no stranded user to protect.
  SELECT COUNT(*) INTO v_confirmed_count
  FROM public.raid_queues WHERE raid_id = p_raid_id AND status = 'confirmed';
  IF v_confirmed_count < 1 THEN RETURN false; END IF;

  -- Destroy the raid: set is_active = false and status = 'cancelled' atomically.
  UPDATE public.raids
  SET is_active = false,
      status = 'cancelled'::raid_status_enum
  WHERE id = p_raid_id;

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
  -- Covers queued/invited/confirmed — all must be moved off the dead raid.
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

  -- Cancel original entries (all statuses on the dead raid)
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
