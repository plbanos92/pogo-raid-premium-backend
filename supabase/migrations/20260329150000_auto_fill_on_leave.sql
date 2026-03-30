-- Auto-fill the next queued user when a joiner leaves a lobby.
-- Cancelled rows keep the existing recompute-only behavior.

CREATE OR REPLACE FUNCTION public.promote_next_queued_user(p_raid_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_raid_id::text));

  WITH candidate AS (
    SELECT q.id
    FROM public.raid_queues q
    WHERE q.raid_id = p_raid_id
      AND q.status = 'queued'
    ORDER BY q.is_vip DESC, q.joined_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.raid_queues q
  SET status = 'invited',
      invited_at = now(),
      updated_at = now()
  FROM candidate c
  WHERE q.id = c.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.recompute_queue_positions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('left', 'cancelled')
     AND OLD.status NOT IN ('left', 'cancelled') THEN
    PERFORM pg_advisory_xact_lock(hashtext(NEW.raid_id::text));

    UPDATE public.raid_queues q
    SET position = sub.new_pos
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY raid_id ORDER BY is_vip DESC, joined_at ASC
             ) AS new_pos
      FROM public.raid_queues
      WHERE raid_id = NEW.raid_id AND status IN ('queued', 'invited')
    ) sub
    WHERE q.id = sub.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_positions ON public.raid_queues;
CREATE TRIGGER trg_recompute_positions
AFTER UPDATE ON public.raid_queues
FOR EACH ROW EXECUTE FUNCTION public.recompute_queue_positions();