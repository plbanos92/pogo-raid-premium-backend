-- Migration: Account screen enhancements
-- Adds trainer_level, team to user_profiles
-- Creates RPC get_my_account_stats() for account screen data

-- 1. New columns
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS trainer_level smallint
    CHECK (trainer_level BETWEEN 1 AND 50),
  ADD COLUMN IF NOT EXISTS team text
    CHECK (team IN ('mystic', 'valor', 'instinct'));

-- 2. RPC: get_my_account_stats
-- Returns email, member_since, raids_joined, raids_hosted for current user
CREATE OR REPLACE FUNCTION public.get_my_account_stats()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_email        text;
  v_member_since timestamptz;
  v_raids_joined int;
  v_raids_hosted int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT email INTO v_email
  FROM auth.users WHERE id = v_uid;

  SELECT created_at INTO v_member_since
  FROM public.user_profiles WHERE auth_id = v_uid;

  SELECT COUNT(*)::int INTO v_raids_joined
  FROM public.raid_queues
  WHERE user_id = v_uid AND status IN ('done', 'raiding');

  SELECT COUNT(*)::int INTO v_raids_hosted
  FROM public.raids
  WHERE host_user_id = v_uid;

  RETURN json_build_object(
    'email',        COALESCE(v_email, ''),
    'member_since', v_member_since,
    'raids_joined', COALESCE(v_raids_joined, 0),
    'raids_hosted', COALESCE(v_raids_hosted, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_account_stats() TO authenticated;
