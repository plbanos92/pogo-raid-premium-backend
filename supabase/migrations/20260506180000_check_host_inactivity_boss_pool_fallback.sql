-- Fix: check_host_inactivity dropped joiners from the queue pool when the
-- cancelled raid had no sibling active raid for the same boss. Previously
-- the per-user re-queue only fired inside `IF v_new_raid_id IS NOT NULL`,
-- and the unconditional `UPDATE ... SET status = 'cancelled'` then wiped
-- every queued/invited/confirmed entry from the dead raid — leaving the
-- user with no active row anywhere.
--
-- Audit evidence (raid 4f731bab-…, 2026-04-30 14:27:37):
--   queue 513e20ee-…: confirmed -> cancelled
--   raid  4f731bab-…: lobby     -> cancelled
-- The joiner had no other raid_queues row afterwards. They had to manually
-- re-join the boss queue to be findable again.
--
-- This migration adds an "Option 3" boss-pool fallback: when no sibling
-- raid is available, convert the affected rows in place to a boss-level
-- pool entry (raid_id = NULL, status = 'queued', is_vip = true so priority
-- is restored). If a partial unique index would be violated (the user
-- already has a boss-pool row queued for this boss), fall back to the
-- old behaviour of just cancelling the row.
--
-- All other guards from 20260505100000_state_machine_audit_fixes.sql are
-- preserved verbatim (status-in-(open,lobby) short-circuit, configurable
-- timeout from app_config, confirmed_count >= 1 guard, sibling-raid path).

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

  -- Only run inactivity sweep for open/lobby raids.
  IF v_raid.status NOT IN ('open', 'lobby') THEN
    RETURN false;
  END IF;

  -- Read configurable timeout (seconds) from app_config
  SELECT host_inactivity_seconds INTO v_timeout FROM public.app_config WHERE id = 1;

  -- Has host been inactive longer than the configured timeout?
  IF v_raid.last_host_action_at >= now() - (v_timeout * interval '1 second') THEN
    RETURN false;
  END IF;

  -- Guard: only fire if at least one player has confirmed.
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

  IF v_new_raid_id IS NOT NULL THEN
    -- Sibling raid available: insert priority-boosted rows there and
    -- cancel the originals on the dead raid.
    FOR v_entry IN
      SELECT user_id, note FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed')
    LOOP
      INSERT INTO public.raid_queues (raid_id, user_id, status, is_vip, note)
      VALUES (v_new_raid_id, v_entry.user_id, 'queued', true,
              'Re-queued (host inactivity) — priority restored')
      ON CONFLICT (raid_id, user_id) DO NOTHING;
    END LOOP;

    UPDATE public.raid_queues SET status = 'cancelled'
    WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed');

    -- Recompute positions in new raid
    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = v_new_raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  ELSE
    -- No sibling raid: convert each affected row in place to a boss-pool
    -- entry so the user remains findable when the next raid for this boss
    -- hatches. Falls back to cancellation only if a unique-index conflict
    -- prevents the conversion (user already has a boss-pool queue row).
    FOR v_entry IN
      SELECT id, status FROM public.raid_queues
      WHERE raid_id = p_raid_id AND status IN ('queued', 'invited', 'confirmed')
    LOOP
      BEGIN
        UPDATE public.raid_queues
        SET raid_id    = NULL,
            boss_id    = v_raid.raid_boss_id,
            status     = 'queued',
            position   = NULL,
            invited_at = NULL,
            is_vip     = true,
            joined_at  = now(),
            note       = 'Re-queued (host inactivity, boss pool) — priority restored',
            updated_at = now()
        WHERE id = v_entry.id;
      EXCEPTION WHEN unique_violation THEN
        -- User already has an active boss-pool entry for this boss; cancel
        -- the dead-raid row (the existing boss-pool row keeps them in the
        -- pool).
        UPDATE public.raid_queues SET status = 'cancelled'
        WHERE id = v_entry.id;
      END;
    END LOOP;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_host_inactivity(uuid) TO authenticated;
