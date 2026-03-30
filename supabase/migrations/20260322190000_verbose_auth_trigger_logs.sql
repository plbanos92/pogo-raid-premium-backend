-- Migration: add verbose RAISE LOG statements to handle_new_user trigger
-- Logs are visible in Supabase Dashboard → Logs → postgres

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RAISE LOG 'handle_new_user: triggered for auth.users id=%, email=%', NEW.id, NEW.email;

  INSERT INTO public.user_profiles (auth_id)
  VALUES (NEW.id)
  ON CONFLICT (auth_id) DO NOTHING;

  IF FOUND THEN
    RAISE LOG 'handle_new_user: user_profiles row created for auth_id=%', NEW.id;
  ELSE
    RAISE LOG 'handle_new_user: user_profiles row already existed for auth_id=% (ON CONFLICT DO NOTHING)', NEW.id;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user: unexpected error for auth_id=% — %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;
