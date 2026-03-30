-- Phase 8: Server-side invite expiry wrapper
-- Called by the expire-stale-invites Edge Function (scheduled every minute).
-- Loops all non-terminal raids and calls expire_stale_invites for each.
-- Uses status NOT IN ('completed', 'cancelled') — Phase 3 predicate.
--
-- Decision: browser-side runQueueMaintenance expiry is RETAINED.
-- Overlapping client+server is safe (expire_stale_invites is idempotent)
-- and provides redundancy: the Edge Function catches idle sessions while
-- the browser-side call accelerates expiry for active users.

CREATE OR REPLACE FUNCTION public.expire_stale_invites_all()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  v_total int := 0;
  v_count int;
BEGIN
  FOR r IN
    SELECT id FROM public.raids
    WHERE status NOT IN ('completed', 'cancelled')
  LOOP
    SELECT public.expire_stale_invites(r.id) INTO v_count;
    v_total := v_total + COALESCE(v_count, 0);
  END LOOP;
  RETURN v_total;
END;
$$;

-- Only service_role needs direct RPC access; authenticated users use the per-raid version
GRANT EXECUTE ON FUNCTION public.expire_stale_invites_all() TO service_role;
