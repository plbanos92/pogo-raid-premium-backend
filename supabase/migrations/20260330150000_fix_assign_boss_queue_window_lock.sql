-- Fix: FOR UPDATE cannot be combined with window functions in PostgreSQL.
-- Split into a locking subquery + outer window function.

CREATE OR REPLACE FUNCTION public.assign_boss_queue_on_raid_create()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.raid_boss_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Auto-assign waiting boss-level entries to the new raid.
  -- VIP first, then by earliest join time, up to raid capacity.
  -- Step 1: lock candidate rows (no window function here).
  -- Step 2: assign position via ROW_NUMBER in the UPDATE.
  WITH locked AS (
    SELECT id
    FROM public.raid_queues
    WHERE boss_id = NEW.raid_boss_id
      AND raid_id IS NULL
      AND status = 'queued'
      AND user_id <> NEW.host_user_id
    ORDER BY is_vip DESC, joined_at ASC
    LIMIT NEW.capacity
    FOR UPDATE
  ),
  ranked AS (
    SELECT l.id,
           ROW_NUMBER() OVER (ORDER BY q.is_vip DESC, q.joined_at ASC) AS rn
    FROM locked l
    JOIN public.raid_queues q ON q.id = l.id
  )
  UPDATE public.raid_queues upd
  SET raid_id    = NEW.id,
      status     = 'invited',
      invited_at = now(),
      position   = r.rn
  FROM ranked r
  WHERE upd.id = r.id;

  RETURN NEW;
END;
$$;
