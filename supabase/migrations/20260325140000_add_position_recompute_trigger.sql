-- Migration E: Position recompute trigger on leave/cancel
-- Phase 1 — Invite & Confirm Flow

-- When a row transitions to 'left' or 'cancelled', renumber remaining positions
CREATE OR REPLACE FUNCTION public.recompute_queue_positions()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status IN ('left', 'cancelled')
     AND OLD.status NOT IN ('left', 'cancelled') THEN
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_recompute_positions ON public.raid_queues;
CREATE TRIGGER trg_recompute_positions
AFTER UPDATE ON public.raid_queues
FOR EACH ROW EXECUTE FUNCTION public.recompute_queue_positions();
