-- Migration C: start_raid RPC + last_host_action_at/host_finished_at columns + raiding/done status values
-- Phase 2 — Host Lobby & Raid Lifecycle

-- Track when host last took an action (for inactivity timeout)
ALTER TABLE public.raids
  ADD COLUMN IF NOT EXISTS last_host_action_at timestamptz DEFAULT now();

-- Track when host finishes raiding (NULL = still raiding or lobby phase)
ALTER TABLE public.raids
  ADD COLUMN IF NOT EXISTS host_finished_at timestamptz;

-- Add 'raiding' and 'done' to the status CHECK constraint
ALTER TABLE public.raid_queues
  DROP CONSTRAINT IF EXISTS raid_queues_status_chk;
ALTER TABLE public.raid_queues
  ADD CONSTRAINT raid_queues_status_chk
  CHECK (status IN ('queued','invited','confirmed','raiding','done','declined','cancelled','left')) NOT VALID;

-- Update last_host_action_at when host updates their raid
CREATE OR REPLACE FUNCTION public.refresh_host_action_at()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.host_user_id = auth.uid() THEN
    NEW.last_host_action_at = now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_refresh_host_action_at ON public.raids;
CREATE TRIGGER trg_refresh_host_action_at
BEFORE UPDATE ON public.raids
FOR EACH ROW EXECUTE FUNCTION public.refresh_host_action_at();

-- RPC: host starts the raid (confirmed → raiding, cancel stragglers)
CREATE OR REPLACE FUNCTION public.start_raid(p_raid_id uuid)
RETURNS public.raids
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_raid public.raids%ROWTYPE;
  v_confirmed int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_raid FROM public.raids
  WHERE id = p_raid_id AND host_user_id = v_uid AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or already inactive'
      USING ERRCODE = '42501';
  END IF;

  -- Must have at least one confirmed participant
  SELECT COUNT(*) INTO v_confirmed
  FROM public.raid_queues
  WHERE raid_id = p_raid_id AND status = 'confirmed';
  IF v_confirmed = 0 THEN
    RAISE EXCEPTION 'No confirmed participants to start with';
  END IF;

  -- Transition confirmed → raiding
  UPDATE public.raid_queues SET status = 'raiding'
  WHERE raid_id = p_raid_id AND status = 'confirmed';

  -- Cancel users who hadn't confirmed yet
  UPDATE public.raid_queues SET status = 'cancelled'
  WHERE raid_id = p_raid_id AND status IN ('queued', 'invited');

  -- Raid stays is_active = true (raiding in progress)
  -- Reset host_finished_at in case of any stale data
  UPDATE public.raids SET host_finished_at = NULL
  WHERE id = p_raid_id
  RETURNING * INTO v_raid;

  RETURN v_raid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_raid(uuid) TO authenticated;
