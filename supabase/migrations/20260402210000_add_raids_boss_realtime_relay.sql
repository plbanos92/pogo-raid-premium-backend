-- Relay raids INSERT/UPDATE through raid_bosses.updated_at for realtime broadcast.
--
-- Problem: when a host creates or cancels a raid, the boss card active_hosts counter
-- must update for all connected clients. Channel 3 (raids postgres_changes) exists
-- but has been unreliable for non-owner observers due to RLS interaction with the
-- Supabase realtime server. The relay approach (used for raid_queues in migration
-- 20260402200000) is the proven reliable path: touch raid_bosses.updated_at via a
-- SECURITY DEFINER trigger, which fires Channel 5 on the publicly-readable table.
--
-- Trigger fires on:
--   INSERT  — host creates a new raid    → active_hosts↑
--   UPDATE OF status  — host cancels/completes → active_hosts↓
--   UPDATE OF is_active — any is_active change that affects the count

CREATE OR REPLACE FUNCTION public.notify_raids_boss_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_boss_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_boss_id := OLD.raid_boss_id;
  ELSE
    v_boss_id := NEW.raid_boss_id;
  END IF;

  IF v_boss_id IS NOT NULL THEN
    UPDATE public.raid_bosses SET updated_at = now() WHERE id = v_boss_id;
  END IF;

  RETURN NULL; -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_raids_boss_change ON public.raids;
CREATE TRIGGER trg_notify_raids_boss_change
  AFTER INSERT OR UPDATE OF status, is_active OR DELETE ON public.raids
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_raids_boss_change();
