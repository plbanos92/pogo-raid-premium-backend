-- Fix: promote_next_queued_user was missing from production schema despite
-- migration 20260329150000 being recorded as applied (silent partial failure).
-- Re-creates the function so leave_queue_and_promote can call it.

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

GRANT EXECUTE ON FUNCTION public.promote_next_queued_user(uuid) TO authenticated;
