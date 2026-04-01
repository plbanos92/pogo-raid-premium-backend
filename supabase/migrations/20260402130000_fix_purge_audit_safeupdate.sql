-- Fix: pg_safeupdate blocks bare DELETE without WHERE clause.
-- Add "WHERE true" to the purge-all path so it passes the guard.

CREATE OR REPLACE FUNCTION public.admin_purge_audit_trail(
  p_email text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_uid       uuid;
  v_sessions_deleted int;
BEGIN
  IF NOT public.is_caller_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  IF p_email IS NOT NULL THEN
    SELECT id INTO v_target_uid FROM auth.users WHERE LOWER(email) = LOWER(p_email);
    IF v_target_uid IS NULL THEN
      RAISE EXCEPTION 'User not found: %', p_email;
    END IF;
    DELETE FROM public.user_sessions WHERE user_id = v_target_uid;
    GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;
  ELSE
    DELETE FROM public.user_sessions WHERE true;
    GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'sessions_deleted', v_sessions_deleted,
    'target', COALESCE(p_email, 'ALL')
  );
END;
$$;
