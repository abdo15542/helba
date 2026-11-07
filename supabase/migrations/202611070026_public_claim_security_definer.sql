-- HELBA: Make public.claim_prekey_bundle SECURITY DEFINER (migration 026).
-- Apply after 025. Self-contained and safe to re-run.
--
-- The private function is already SECURITY DEFINER (it bypasses RLS
-- for the consuming UPDATEs). Making the public wrapper SECURITY
-- DEFINER too aligns both layers, so the whole claim runs as the
-- function owner (postgres) and there is no doubt that RLS on the
-- pre-key tables could reject a claim for another user's keys when
-- the app calls the public function via PostgREST as an authenticated
-- user. The signature and the returned column names are UNCHANGED,
-- and auth.uid() inside the private function still reads the caller's
-- UUID from the request JWT, so the authentication check is intact.
-- Server-side-only fix — the app (build 127) needs no rebuild.

create or replace function public.claim_prekey_bundle(
  p_user_id uuid,
  p_device_id text
)
returns table (
  identity_key text,
  registration_id int,
  signed_prekey_id int,
  signed_prekey_public text,
  signed_prekey_signature text,
  signed_prekey_created_at timestamptz,
  prekey_id int,
  prekey_public text,
  kyber_prekey_id int,
  kyber_prekey_public text,
  kyber_prekey_signature text
)
language sql
security definer
set search_path = public, private, pg_temp
as $$
  select * from private.claim_prekey_bundle(p_user_id, p_device_id);
$$;

revoke all on function public.claim_prekey_bundle(uuid, text)
  from public, anon;
grant execute on function public.claim_prekey_bundle(uuid, text)
  to authenticated;
