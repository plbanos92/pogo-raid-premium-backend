-- Relay boss-level raid_queues changes through raid_bosses for realtime broadcast.
--
-- Problem: boss-level queue entries (raid_id = NULL) only pass RLS for their owner.
-- Channel 4 (raid_queues postgres_changes) therefore never delivers INSERT/UPDATE
-- events to observer clients (e.g. the host watching the boss card queue_length).
--
-- Fix: add updated_at to raid_bosses, add it to the realtime publication, and
-- fire a SECURITY DEFINER trigger on raid_queues status changes to touch
-- raid_bosses.updated_at. Since raid_bosses is publicly readable (anon + authenticated),
-- Channel 5 on the frontend receives the event and triggers a debounced refreshData().

-- 1. Add updated_at column to raid_bosses
ALTER TABLE public.raid_bosses
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Back-fill existing rows
UPDATE public.raid_bosses SET updated_at = created_at WHERE updated_at = now() AND created_at < now();

-- 2. Add raid_bosses to the Supabase Realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.raid_bosses;

-- 3. Trigger function — touches raid_bosses.updated_at on any raid_queues status change.
--    Resolves boss_id from either the direct boss_id column (boss-level entries)
--    or via raids.raid_boss_id (raid-level entries).
--    SECURITY DEFINER ensures it can always UPDATE raid_bosses regardless of RLS.
CREATE OR REPLACE FUNCTION public.notify_boss_queue_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_boss_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_boss_id := OLD.boss_id;
    IF v_boss_id IS NULL AND OLD.raid_id IS NOT NULL THEN
      SELECT raid_boss_id INTO v_boss_id FROM public.raids WHERE id = OLD.raid_id;
    END IF;
  ELSE
    v_boss_id := NEW.boss_id;
    IF v_boss_id IS NULL AND NEW.raid_id IS NOT NULL THEN
      SELECT raid_boss_id INTO v_boss_id FROM public.raids WHERE id = NEW.raid_id;
    END IF;
  END IF;

  IF v_boss_id IS NOT NULL THEN
    UPDATE public.raid_bosses SET updated_at = now() WHERE id = v_boss_id;
  END IF;

  RETURN NULL; -- AFTER trigger; return value is ignored
END;
$$;

-- 4. Attach trigger to raid_queues.
--    Fires on INSERT (new joiner), UPDATE OF status (leave/invite/confirm/cancel),
--    and DELETE (terminal-entry cleanup inside join_boss_queue).
DROP TRIGGER IF EXISTS trg_notify_boss_queue_change ON public.raid_queues;
CREATE TRIGGER trg_notify_boss_queue_change
  AFTER INSERT OR UPDATE OF status OR DELETE ON public.raid_queues
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_boss_queue_change();
