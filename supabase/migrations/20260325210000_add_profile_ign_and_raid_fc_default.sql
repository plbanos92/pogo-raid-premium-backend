-- Migration H: in_game_name column + list_raid_queue RPC + friend-code auto-populate trigger
-- Phase 2 — Host Lobby & Raid Lifecycle

-- Add in_game_name column to user_profiles
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS in_game_name text;

-- RPC: list raid queue entries with joiner profile data (host only)
-- Bypasses user_profiles RLS since the host needs to see joiners' friend codes
CREATE OR REPLACE FUNCTION public.list_raid_queue(p_raid_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
  "position" int,
  is_vip boolean,
  note text,
  joined_at timestamptz,
  invited_at timestamptz,
  display_name text,
  in_game_name text,
  friend_code text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Verify caller is the host of this raid
  IF NOT EXISTS (
    SELECT 1 FROM public.raids
    WHERE raids.id = p_raid_id AND host_user_id = v_uid AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Raid not found, not owned by you, or inactive'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    rq.id,
    rq.user_id,
    rq.status,
    rq.position,
    rq.is_vip,
    rq.note,
    rq.joined_at,
    rq.invited_at,
    up.display_name,
    up.in_game_name,
    up.friend_code
  FROM public.raid_queues rq
  LEFT JOIN public.user_profiles up ON up.auth_id = rq.user_id
  WHERE rq.raid_id = p_raid_id
    AND rq.status IN ('queued', 'invited', 'confirmed', 'raiding', 'done')
  ORDER BY rq.is_vip DESC, rq.joined_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_raid_queue(uuid) TO authenticated;

-- Trigger: auto-populate raids.friend_code from host profile if not provided
CREATE OR REPLACE FUNCTION public.default_raid_friend_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.friend_code IS NULL OR NEW.friend_code = '' THEN
    SELECT friend_code INTO NEW.friend_code
    FROM public.user_profiles
    WHERE auth_id = NEW.host_user_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_default_raid_friend_code ON public.raids;
CREATE TRIGGER trg_default_raid_friend_code
BEFORE INSERT ON public.raids
FOR EACH ROW EXECUTE FUNCTION public.default_raid_friend_code();
