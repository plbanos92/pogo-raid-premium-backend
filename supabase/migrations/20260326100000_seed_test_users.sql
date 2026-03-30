-- Phase 2.5: Create two test users for QA testing.
-- The on_auth_user_created trigger auto-creates user_profiles rows.
-- These are auto-confirmed (no email verification needed).

-- Ensure pgcrypto is available for crypt/gen_salt
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Clean up any partial rows from previous failed attempt
DELETE FROM auth.identities WHERE user_id IN (
  'a1111111-1111-1111-1111-111111111111',
  'b2222222-2222-2222-2222-222222222222'
);
DELETE FROM auth.users WHERE id IN (
  'a1111111-1111-1111-1111-111111111111',
  'b2222222-2222-2222-2222-222222222222'
);
DELETE FROM public.user_profiles WHERE auth_id IN (
  'a1111111-1111-1111-1111-111111111111',
  'b2222222-2222-2222-2222-222222222222'
);

-- Test Host: test-host-001
INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  confirmation_sent_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES (
  'a1111111-1111-1111-1111-111111111111',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  'test-host@raidsync.local',
  extensions.crypt('TestHost123!', extensions.gen_salt('bf')),
  now(), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  false, false
);

-- Identity for host (id auto-generated, last_sign_in_at set)
INSERT INTO auth.identities (
  user_id, identity_data, provider, provider_id,
  last_sign_in_at, created_at, updated_at
) VALUES (
  'a1111111-1111-1111-1111-111111111111',
  '{"sub":"a1111111-1111-1111-1111-111111111111","email":"test-host@raidsync.local"}'::jsonb,
  'email',
  'a1111111-1111-1111-1111-111111111111',
  now(), now(), now()
);

-- Test Joiner: test-joiner-001
INSERT INTO auth.users (
  id, instance_id, aud, role, email,
  encrypted_password, email_confirmed_at,
  confirmation_sent_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_sso_user, is_anonymous
) VALUES (
  'b2222222-2222-2222-2222-222222222222',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  'test-joiner@raidsync.local',
  extensions.crypt('TestJoiner123!', extensions.gen_salt('bf')),
  now(), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  false, false
);

-- Identity for joiner (id auto-generated, last_sign_in_at set)
INSERT INTO auth.identities (
  user_id, identity_data, provider, provider_id,
  last_sign_in_at, created_at, updated_at
) VALUES (
  'b2222222-2222-2222-2222-222222222222',
  '{"sub":"b2222222-2222-2222-2222-222222222222","email":"test-joiner@raidsync.local"}'::jsonb,
  'email',
  'b2222222-2222-2222-2222-222222222222',
  now(), now(), now()
);
