-- HELBA: Fix claim_prekey_bundle (migration 025).
-- Apply after 024. Self-contained and safe to re-run.
--
-- BUG (found 2026-11-07, live test): private.claim_prekey_bundle
-- failed on EVERY call with:
--   ERROR 42702: column reference "prekey_id" is ambiguous
--   DETAIL: It could refer to either a PL/pgSQL variable or a table
--   column.
--   CONTEXT: PL/pgSQL function private.claim_prekey_bundle line 31
-- Because the function RETURNS TABLE, its output columns
-- (prekey_id, prekey_public, kyber_prekey_id, ...) are PL/pgSQL
-- variables inside the body. The one-time-pre-key SELECT (and the
-- Kyber SELECTs) referenced the bare column name "prekey_id", which
-- collides with the OUT variable of the same name, so Postgres
-- aborted the claim before consuming anything. That is why NO
-- one-time pre-key was ever consumed and no Signal session could be
-- built, even though both phones published full bundles (build 127).
--
-- FIX: qualify every column reference in the three SELECTs (and the
-- two consuming UPDATEs) with the table alias / table name, so there
-- is no name collision with the OUT variables. The function's
-- signature and its returned column names are UNCHANGED, so the app
-- (build 127) needs no rebuild — this is a server-side-only fix.

create or replace function private.claim_prekey_bundle(
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
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bundle public.signal_bundles%rowtype;
  v_prekey_id int;
  v_prekey_public text;
  v_kyber_id int;
  v_kyber_public text;
  v_kyber_signature text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if p_user_id is null or p_device_id is null or btrim(p_device_id) = '' then
    raise exception 'Recipient user and device are required';
  end if;

  -- The bundle row (no lock needed: it is only ever upserted by its
  -- owner, and a concurrent upsert cannot change the public key
  -- material this claim returns in a way that breaks the session —
  -- the signed pre-key is stable across re-publishes).
  select * into v_bundle
  from public.signal_bundles
  where user_id = p_user_id and device_id = p_device_id;
  if not found then
    return;
  end if;

  -- One unconsumed one-time pre-key (lowest id), claimed atomically.
  -- SKIP LOCKED lets concurrent claimants take different keys instead
  -- of blocking on each other.
  -- NOTE: columns are qualified with the alias (otp.) — the bare
  -- name "prekey_id" collides with this function's OUT variable of
  -- the same name (error 42702) and aborts the claim.
  select otp.prekey_id, otp.public_key into v_prekey_id, v_prekey_public
  from public.signal_one_time_prekeys as otp
  where otp.user_id = p_user_id
    and otp.device_id = p_device_id
    and otp.consumed_at is null
  order by otp.prekey_id asc
  limit 1
  for update skip locked;
  if v_prekey_id is not null then
    update public.signal_one_time_prekeys
    set consumed_at = now()
    where signal_one_time_prekeys.user_id = p_user_id
      and signal_one_time_prekeys.device_id = p_device_id
      and signal_one_time_prekeys.prekey_id = v_prekey_id;
  end if;

  -- One unconsumed one-time Kyber pre-key (lowest id), claimed the
  -- same way. When none remains, fall back to the last-resort Kyber
  -- key (never consumed), so the bundle always carries a Kyber key.
  select kp.prekey_id, kp.public_key, kp.signature
    into v_kyber_id, v_kyber_public, v_kyber_signature
  from public.signal_kyber_prekeys as kp
  where kp.user_id = p_user_id
    and kp.device_id = p_device_id
    and kp.consumed_at is null
    and kp.is_last_resort = false
  order by kp.prekey_id asc
  limit 1
  for update skip locked;
  if v_kyber_id is not null then
    update public.signal_kyber_prekeys
    set consumed_at = now()
    where signal_kyber_prekeys.user_id = p_user_id
      and signal_kyber_prekeys.device_id = p_device_id
      and signal_kyber_prekeys.prekey_id = v_kyber_id;
  else
    select kp.prekey_id, kp.public_key, kp.signature
      into v_kyber_id, v_kyber_public, v_kyber_signature
    from public.signal_kyber_prekeys as kp
    where kp.user_id = p_user_id
      and kp.device_id = p_device_id
      and kp.is_last_resort = true
    order by kp.prekey_id asc
    limit 1;
  end if;

  return query select
    v_bundle.identity_key,
    v_bundle.registration_id,
    v_bundle.signed_prekey_id,
    v_bundle.signed_prekey_public,
    v_bundle.signed_prekey_signature,
    v_bundle.signed_prekey_created_at,
    v_prekey_id,
    v_prekey_public,
    v_kyber_id,
    v_kyber_public,
    v_kyber_signature;
end;
$$;

revoke all on function private.claim_prekey_bundle(uuid, text)
  from public, anon;
grant execute on function private.claim_prekey_bundle(uuid, text)
  to authenticated;
