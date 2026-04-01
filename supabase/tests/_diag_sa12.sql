-- SA-12 diagnostic: simulate exact SA-12 sequence to find root cause of SA-12b failure
BEGIN;

INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES
  ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000000','authenticated','authenticated','smoke-host-011@raidsync.local','',now(),now(),now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false, false),
  ('00000000-0000-0000-0000-000000000021','00000000-0000-0000-0000-000000000000','authenticated','authenticated','smoke-user-021@raidsync.local','',now(),now(),now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_profiles (auth_id, is_admin)
VALUES
  ('00000000-0000-0000-0000-000000000011', true),
  ('00000000-0000-0000-0000-000000000021', false)
ON CONFLICT (auth_id) DO UPDATE SET is_admin = EXCLUDED.is_admin;

SET LOCAL ROLE authenticated;

-- Simulate SA-12a: set to non-admin, catch 42501 exception
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);

DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_purge_audit_trail('anyone@example.com');
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-12a failed';
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Now check: what is jwt.claim.sub AFTER the SA-12a DO block?
DO $$
BEGIN
  RAISE NOTICE 'DIAG after SA-12a: jwt_sub=%, is_caller_admin=%',
    current_setting('request.jwt.claim.sub', true),
    public.is_caller_admin();
END;
$$ LANGUAGE plpgsql;

-- Simulate SA-12b setup: switch to admin
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

-- Check immediately after set_config
DO $$
BEGIN
  RAISE NOTICE 'DIAG before SA-12b call: jwt_sub=%, is_caller_admin=%',
    current_setting('request.jwt.claim.sub', true),
    public.is_caller_admin();
END;
$$ LANGUAGE plpgsql;

-- Simulate SA-12b: call function with nonexistent email
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_purge_audit_trail('nonexistent@raidsync.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'DIAG SA-12b caught: SQLSTATE=%, SQLERRM=%', SQLSTATE, SQLERRM;
    IF SQLERRM LIKE '%User not found%' THEN
      v_caught := true;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'SA-12b: admin_purge_audit_trail must raise "User not found" for unknown email';
  END IF;
END;
$$ LANGUAGE plpgsql;

RAISE NOTICE 'All SA-12 diagnostics passed';

ROLLBACK;

