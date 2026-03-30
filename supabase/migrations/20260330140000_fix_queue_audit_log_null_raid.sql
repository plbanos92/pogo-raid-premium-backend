-- Fix log_queue_status_change to skip boss-level entries (raid_id IS NULL).
-- The raid_state_transitions.raid_id column is NOT NULL, so we must guard against
-- queue entries that have no raid assigned yet.

CREATE OR REPLACE FUNCTION public.log_queue_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Boss-level entries have no raid; skip audit log.
  IF NEW.raid_id IS NULL THEN
    RETURN NULL;
  END IF;

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
