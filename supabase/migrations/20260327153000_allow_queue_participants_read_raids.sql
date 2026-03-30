-- Allow queue participants to read raid rows tied to their own queue entries.
-- This keeps status cards resolvable after a raid becomes inactive, including
-- the transient done state used by the Phase 2.5 test accounts.

CREATE OR REPLACE FUNCTION public.is_queue_participant(p_raid_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.raid_queues rq
    WHERE rq.raid_id = p_raid_id
      AND rq.user_id = auth.uid()
      AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  );
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'raids'
      AND policyname = 'Queue participants read own raids'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY "Queue participants read own raids" ON public.raids
      FOR SELECT
      TO authenticated
      USING (public.is_queue_participant(id))
    $policy$;
  END IF;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION public.is_queue_participant(uuid) TO authenticated;