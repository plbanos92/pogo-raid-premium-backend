-- Migration: definitive fix for auth.users → user_profiles trigger
-- Previous migrations may have created the function but the trigger on auth.users
-- might not have been created due to schema permission issues.
-- This migration uses explicit role grants and backfills any missing rows.

-- 1. Ensure postgres role can create triggers on auth.users
GRANT USAGE ON SCHEMA auth TO postgres;
GRANT SELECT ON auth.users TO postgres;

-- 2. Recreate the function (no EXCEPTION swallowing — let errors surface)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RAISE LOG '[handle_new_user] triggered — auth_id=%, email=%', NEW.id, NEW.email;
  INSERT INTO public.user_profiles (auth_id)
  VALUES (NEW.id)
  ON CONFLICT (auth_id) DO NOTHING;
  RAISE LOG '[handle_new_user] user_profiles upsert complete — auth_id=%', NEW.id;
  RETURN NEW;
END;
$$;

-- 3. Ensure function is owned by postgres (superuser) for SECURITY DEFINER
ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

-- 4. Drop and recreate trigger
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE PROCEDURE public.handle_new_user();

-- 5. Backfill: create user_profiles for any auth.users that are missing one
INSERT INTO public.user_profiles (auth_id)
SELECT id FROM auth.users
WHERE id NOT IN (SELECT auth_id FROM public.user_profiles WHERE auth_id IS NOT NULL)
ON CONFLICT (auth_id) DO NOTHING;

-- 6. Log how many rows were backfilled
DO $$
DECLARE
  auth_count int;
  profile_count int;
BEGIN
  SELECT count(*) INTO auth_count FROM auth.users;
  SELECT count(*) INTO profile_count FROM public.user_profiles;
  RAISE LOG '[backfill] auth.users: %, user_profiles: %', auth_count, profile_count;
END;
$$;
