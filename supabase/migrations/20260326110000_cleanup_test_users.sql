-- Fix: Clean up test users that may have caused schema issues.
-- Delete identities first (FK), then users, then profiles.
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
