-- Phase 9: Add audit log for raid and queue state transitions
-- Creates raid_state_transitions table, RLS, triggers, and indexes for lifecycle observability.
--
-- actor_user_id will be NULL for system-driven transitions (e.g. check_host_inactivity
-- runs as service_role with no JWT), which is expected and correct.
-- action_source is always 'rpc' for now; 'system' and 'trigger' are reserved for future use.

-- 1. Create audit log table
CREATE TABLE public.raid_state_transitions (
  id               uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  raid_id          uuid NOT NULL REFERENCES public.raids(id) ON DELETE CASCADE,
  queue_entry_id   uuid REFERENCES public.raid_queues(id) ON DELETE SET NULL,
  actor_user_id    uuid,
  from_state       text NOT NULL,
  to_state         text NOT NULL,
  transitioned_at  timestamptz NOT NULL DEFAULT now(),
  action_source    text NOT NULL CHECK (action_source IN ('rpc', 'system', 'trigger'))
);

-- 2. Enable RLS
ALTER TABLE public.raid_state_transitions ENABLE ROW LEVEL SECURITY;

-- 3a. Hosts can SELECT transitions for their own raids
CREATE POLICY "Host can view own raid transitions"
  ON public.raid_state_transitions
  FOR SELECT
  USING (
    auth.uid() = (SELECT host_user_id FROM public.raids WHERE id = raid_state_transitions.raid_id)
  );

-- 3b. Queue participants can SELECT transitions for raids they were queued in
CREATE POLICY "Participant can view raid transitions"
  ON public.raid_state_transitions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.raid_queues
      WHERE raid_id = raid_state_transitions.raid_id
        AND user_id = auth.uid()
    )
  );

-- No INSERT/UPDATE/DELETE for any user role — triggers write via SECURITY DEFINER only

-- 4. Trigger function for raids.status changes
CREATE OR REPLACE FUNCTION public.log_raid_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.raid_state_transitions (
    raid_id,
    queue_entry_id,
    actor_user_id,
    from_state,
    to_state,
    action_source
  ) VALUES (
    NEW.id,
    NULL,
    NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid,
    OLD.status::text,
    NEW.status::text,
    'rpc'
  );
  RETURN NULL;
END;
$$;

-- 5. Trigger for raids.status
DROP TRIGGER IF EXISTS trg_log_raid_status ON public.raids;
CREATE TRIGGER trg_log_raid_status
  AFTER UPDATE ON public.raids
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.log_raid_status_change();

-- 6. Trigger function for raid_queues.status changes
CREATE OR REPLACE FUNCTION public.log_queue_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.raid_state_transitions (
    raid_id,
    queue_entry_id,
    actor_user_id,
    from_state,
    to_state,
    action_source
  ) VALUES (
    NEW.raid_id,
    NEW.id,
    NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid,
    OLD.status,
    NEW.status,
    'rpc'
  );
  RETURN NULL;
END;
$$;

-- 7. Trigger for raid_queues.status
DROP TRIGGER IF EXISTS trg_log_queue_status ON public.raid_queues;
CREATE TRIGGER trg_log_queue_status
  AFTER UPDATE ON public.raid_queues
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.log_queue_status_change();

-- 8. Indexes for common queries
CREATE INDEX idx_rst_raid_id ON public.raid_state_transitions(raid_id);
CREATE INDEX idx_rst_transitioned_at ON public.raid_state_transitions(transitioned_at DESC);
