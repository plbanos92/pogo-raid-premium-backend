-- Migration: auto-create user_profiles row on new auth.users insert
-- Without this trigger, signing up creates auth.users but no user_profiles row.

-- The function must be SECURITY DEFINER so it can write to public.user_profiles
-- even though it fires in the auth schema context.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (auth_id)
  VALUES (NEW.id)
  ON CONFLICT (auth_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Drop first to make migration idempotent
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
