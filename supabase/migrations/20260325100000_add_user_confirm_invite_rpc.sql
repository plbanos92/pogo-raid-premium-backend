-- Migration A: user_confirm_invite RPC + invited_at column + trigger
-- Phase 1 — Invite & Confirm Flow

-- Add invited_at column (set when status transitions to 'invited')
ALTER TABLE public.raid_queues
  ADD COLUMN IF NOT EXISTS invited_at timestamptz;

-- Trigger to auto-set invited_at when status becomes 'invited'
CREATE OR REPLACE FUNCTION public.set_invited_at()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'invited' AND (OLD.status IS DISTINCT FROM 'invited') THEN
    NEW.invited_at = now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_invited_at ON public.raid_queues;
CREATE TRIGGER trg_set_invited_at
BEFORE UPDATE ON public.raid_queues
FOR EACH ROW EXECUTE FUNCTION public.set_invited_at();

-- RPC: user confirms they sent a friend request (invited → confirmed)
CREATE OR REPLACE FUNCTION public.user_confirm_invite(p_queue_id uuid)
RETURNS public.raid_queues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.raid_queues%ROWTYPE;
  v_updated public.raid_queues%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.raid_queues
  WHERE id = p_queue_id AND user_id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Queue entry not found' USING ERRCODE = '42501';
  END IF;

  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'Can only confirm an invited entry, current: %', v_row.status;
  END IF;

  UPDATE public.raid_queues SET status = 'confirmed'
  WHERE id = p_queue_id RETURNING * INTO v_updated;

  INSERT INTO public.raid_confirmations (raid_queue_id, confirmed_by)
  VALUES (p_queue_id, v_uid);

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.user_confirm_invite(uuid) TO authenticated;
