-- HELBA: Signal Protocol pre-key bundles (migration 024).
-- Apply after 001-023. Self-contained and safe to re-run.
--
-- Problem: the old E2E (migration 012/023) wraps ONE conversation key
-- per member/device and keeps failing (a reset wraps only for the
-- resetter; a reinstall orphans the key). WhatsApp's approach is the
-- Signal Protocol: each device publishes a pre-key BUNDLE (identity
-- key, signed pre-key, one-time pre-keys, Kyber pre-keys); a sender
-- builds a session from the recipient's bundle (X3DH + PQXDH) even
-- when the recipient is OFFLINE, then the Double Ratchet gives every
-- message its own key. No shared conversation key, no reset.
--
-- This migration adds the server-side storage for bundles:
--   (a) signal_bundles: one row per (user, device) with the identity
--       key, registration id, and the current signed pre-key.
--   (b) signal_one_time_prekeys: one row per one-time pre-key, with
--       consumed_at set when a sender claims it (one claim per key).
--   (c) signal_kyber_prekeys: one row per Kyber pre-key, with
--       consumed_at set when claimed — plus a last-resort key
--       (is_last_resort) that is NEVER consumed, so a bundle always
--       has a Kyber pre-key available (libsignal REQUIRES Kyber;
--       a bundle without it is rejected). The claim RPC returns the
--       last-resort key when no one-time Kyber pre-key remains.
--   (d) messages.signal_msg_type: nullable text ('prekey' | 'signal')
--       naming the Signal message type for an encrypted row. NULL on
--       old rows (old E2E rows and plaintext stay valid). A Signal row
--       is recognised by is_encrypted=true AND signal_msg_type set;
--       its ciphertext is the base64 Signal ciphertext and its nonce
--       is NULL (the nonce lives inside the serialized Signal
--       ciphertext), which also distinguishes it from old-E2E rows.
--   (e) claim_prekey_bundle RPC: atomically (one transaction,
--       FOR UPDATE SKIP LOCKED) returns the recipient's bundle plus
--       one unconsumed one-time pre-key and one unconsumed Kyber
--       pre-key, marking both consumed. NULLs for the one-time fields
--       when none remain (a session still works without a one-time
--       pre-key; the Kyber field falls back to the last-resort key).
--       The RPC only reads PUBLIC key columns — it never reveals a
--       private key.
--
-- RLS: the bundle tables hold PUBLIC keys. Any authenticated user may
-- SELECT any row (hiding them would break session establishment).
-- INSERT/UPDATE/DELETE are own-rows-only (user_id = auth.uid()).

-- (a) One bundle row per (user, device).
create table if not exists public.signal_bundles (
  user_id uuid not null
    references public.profiles(id) on delete cascade,
  device_id text not null,
  identity_key text not null,
  registration_id int not null,
  signed_prekey_id int not null,
  signed_prekey_public text not null,
  signed_prekey_signature text not null,
  signed_prekey_created_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.signal_bundles enable row level security;

drop policy if exists signal_bundles_select_any on public.signal_bundles;
create policy signal_bundles_select_any on public.signal_bundles
for select to authenticated
using (true);

drop policy if exists signal_bundles_write_own on public.signal_bundles;
create policy signal_bundles_write_own on public.signal_bundles
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert, update, delete on public.signal_bundles to authenticated;

-- (b) One-time pre-keys (X3DH). One claim per key.
create table if not exists public.signal_one_time_prekeys (
  user_id uuid not null
    references public.profiles(id) on delete cascade,
  device_id text not null,
  prekey_id int not null,
  public_key text not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, device_id, prekey_id)
);

alter table public.signal_one_time_prekeys enable row level security;

drop policy if exists signal_one_time_prekeys_select_any
  on public.signal_one_time_prekeys;
create policy signal_one_time_prekeys_select_any
  on public.signal_one_time_prekeys
for select to authenticated
using (true);

drop policy if exists signal_one_time_prekeys_write_own
  on public.signal_one_time_prekeys;
create policy signal_one_time_prekeys_write_own
  on public.signal_one_time_prekeys
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert, update, delete
  on public.signal_one_time_prekeys to authenticated;

-- Helpful index: find an unconsumed one-time pre-key fast.
create index if not exists signal_one_time_prekeys_unconsumed_idx
  on public.signal_one_time_prekeys (user_id, device_id, prekey_id)
  where consumed_at is null;

-- (c) Kyber pre-keys (PQXDH). One claim per one-time key; the
-- last-resort key (is_last_resort) is never consumed.
create table if not exists public.signal_kyber_prekeys (
  user_id uuid not null
    references public.profiles(id) on delete cascade,
  device_id text not null,
  prekey_id int not null,
  public_key text not null,
  signature text not null,
  is_last_resort boolean not null default false,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, device_id, prekey_id)
);

alter table public.signal_kyber_prekeys enable row level security;

drop policy if exists signal_kyber_prekeys_select_any
  on public.signal_kyber_prekeys;
create policy signal_kyber_prekeys_select_any
  on public.signal_kyber_prekeys
for select to authenticated
using (true);

drop policy if exists signal_kyber_prekeys_write_own
  on public.signal_kyber_prekeys;
create policy signal_kyber_prekeys_write_own
  on public.signal_kyber_prekeys
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert, update, delete
  on public.signal_kyber_prekeys to authenticated;

create index if not exists signal_kyber_prekeys_unconsumed_idx
  on public.signal_kyber_prekeys (user_id, device_id, prekey_id)
  where consumed_at is null;

-- (d) Signal message type on messages. Nullable so old rows stay valid.
alter table public.messages
  add column if not exists signal_msg_type text;

-- (e) Atomically claim a recipient's pre-key bundle.
-- Returns one row (or no row when the recipient never published a
-- bundle): the bundle fields plus one unconsumed one-time pre-key
-- and one unconsumed Kyber pre-key (falling back to the last-resort
-- Kyber key), marking both consumed. The caller (the sender) builds
-- a libsignal PreKeyBundle from the returned public columns.
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
  select prekey_id, public_key into v_prekey_id, v_prekey_public
  from public.signal_one_time_prekeys
  where user_id = p_user_id
    and device_id = p_device_id
    and consumed_at is null
  order by prekey_id asc
  limit 1
  for update skip locked;
  if v_prekey_id is not null then
    update public.signal_one_time_prekeys
    set consumed_at = now()
    where user_id = p_user_id
      and device_id = p_device_id
      and prekey_id = v_prekey_id;
  end if;

  -- One unconsumed one-time Kyber pre-key (lowest id), claimed the
  -- same way. When none remains, fall back to the last-resort Kyber
  -- key (never consumed), so the bundle always carries a Kyber key.
  select prekey_id, public_key, signature
    into v_kyber_id, v_kyber_public, v_kyber_signature
  from public.signal_kyber_prekeys
  where user_id = p_user_id
    and device_id = p_device_id
    and consumed_at is null
    and is_last_resort = false
  order by prekey_id asc
  limit 1
  for update skip locked;
  if v_kyber_id is not null then
    update public.signal_kyber_prekeys
    set consumed_at = now()
    where user_id = p_user_id
      and device_id = p_device_id
      and prekey_id = v_kyber_id;
  else
    select prekey_id, public_key, signature
      into v_kyber_id, v_kyber_public, v_kyber_signature
    from public.signal_kyber_prekeys
    where user_id = p_user_id
      and device_id = p_device_id
      and is_last_resort = true
    order by prekey_id asc
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

-- Public thin wrapper (security invoker), same pattern as 016/022.
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
security invoker
set search_path = public, private, pg_temp
as $$
  select * from private.claim_prekey_bundle(p_user_id, p_device_id);
$$;

revoke all on function public.claim_prekey_bundle(uuid, text)
  from public, anon;
grant execute on function public.claim_prekey_bundle(uuid, text)
  to authenticated;
