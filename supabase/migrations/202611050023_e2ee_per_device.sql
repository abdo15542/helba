-- HELBA: per-device E2E keys (migration 023).
-- Apply after 001-022. Self-contained and safe to re-run.
--
-- Problem: one public_key per profile (profiles.public_key) cannot serve
-- the same account on two phones. Each device holds its own X25519
-- keypair (already per-install in secure storage), but the profile
-- holds only the LAST published public key, and conversation_keys has
-- one row per (conversation_id, user_id) — so the two devices keep
-- overwriting each other's wrapped row, and only the device that
-- wrapped last can decrypt.
--
-- Fix:
--   (a) New user_devices table: one row per (user, device) with that
--       device's public key. A user manages only their own rows; any
--       member may SELECT the devices of users they share a
--       conversation with (needed to wrap the key for each device).
--   (b) conversation_keys gains device_id (NULL = the legacy per-user
--       row, wrapped for profiles.public_key, kept so old builds keep
--       working during the transition) and wrapped_by_device_id (which
--       device wrapped the row; NULL on pre-023 rows). The old primary
--       key (conversation_id, user_id) is replaced by a unique
--       constraint on (conversation_id, user_id, device_id) — one
--       wrapped row per device. NULLS NOT DISTINCT (PostgreSQL 15+) makes the NULL
--       device_id of legacy rows behave as one value, so a legacy-row
--       upsert still conflicts with the existing legacy row instead of
--       inserting a duplicate. Supabase runs PostgreSQL 15, so this is
--       safe here; on older PostgreSQL the index creation would fail.
--   (c) ensure_conversation_key (016) is NOT extended with p_device_id:
--       the app uses client-side creator election and never calls the
--       RPC. But its select must now filter to the legacy row
--       (device_id IS NULL): after this migration a user can have
--       several rows (one per device), and the bare select would raise
--       "query returned more than one row". The RPC keeps its exact
--       pre-023 semantics (claim/return the legacy per-user row).

-- (a) One row per (user, device).
create table if not exists public.user_devices (
  user_id uuid not null
    references public.profiles(id) on delete cascade,
  device_id text not null,
  public_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.user_devices enable row level security;

-- A user manages only their own device rows.
drop policy if exists user_devices_own on public.user_devices;
create policy user_devices_own on public.user_devices
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Any member may read the devices of users they share a conversation
-- with: the wrapper needs every device key to wrap for each device.
-- (Permissive policies are OR-ed, so a user still reads their own rows
-- through user_devices_own.)
drop policy if exists user_devices_select_members on public.user_devices;
create policy user_devices_select_members on public.user_devices
for select to authenticated
using (
  exists (
    select 1
    from public.conversation_members mine
    join public.conversation_members theirs
      on theirs.conversation_id = mine.conversation_id
    where mine.user_id = (select auth.uid())
      and theirs.user_id = user_devices.user_id
  )
);

grant select, insert, update, delete on public.user_devices to authenticated;

-- (b) One wrapped row per device.
alter table public.conversation_keys
  add column if not exists device_id text;
alter table public.conversation_keys
  add column if not exists wrapped_by_device_id text;

alter table public.conversation_keys
  drop constraint if exists conversation_keys_pkey;

-- The old PK's index is gone with it; this unique constraint replaces
-- it for lookups by (conversation_id, user_id, device_id) and for the
-- client's upsert conflict target.
alter table public.conversation_keys
  add constraint conversation_keys_user_device_key
  unique nulls not distinct (conversation_id, user_id, device_id);

-- (c) Keep ensure_conversation_key working on the legacy row.
create or replace function private.ensure_conversation_key(p_conversation_id uuid, p_wrapped_key text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_existing text;
begin
  if actor is null then
    raise exception 'Authentication required';
  end if;
  if private.is_banned() then
    raise exception 'Account is banned';
  end if;
  if p_conversation_id is null then
    raise exception 'Conversation id is required';
  end if;
  if p_wrapped_key is null or btrim(p_wrapped_key) = '' then
    raise exception 'Wrapped key is required';
  end if;
  if not exists (
    select 1 from public.conversations where id = p_conversation_id
  ) then
    raise exception 'Conversation not found';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = actor
  ) then
    raise exception 'You are not a member of this conversation';
  end if;

  -- Serialize key creation for this conversation: the lock is held
  -- until the transaction ends, so the select-then-insert below is
  -- atomic across concurrent callers.
  perform pg_advisory_xact_lock(hashtext('convkey:' || p_conversation_id::text));

  -- Legacy per-user row only (device_id IS NULL): after migration 023
  -- a user can hold one wrapped row per device, and the bare select
  -- would fail with "query returned more than one row".
  select wrapped_key into v_existing
  from public.conversation_keys
  where conversation_id = p_conversation_id and user_id = actor
    and device_id is null;

  -- Existing key wins: return it unchanged (see contract in 016).
  if v_existing is not null then
    return v_existing;
  end if;

  insert into public.conversation_keys
    (conversation_id, user_id, wrapped_key, wrapped_by)
  values (p_conversation_id, actor, p_wrapped_key, actor);

  return p_wrapped_key;
end;
$$;

revoke all on function private.ensure_conversation_key(uuid, text) from public, anon;
grant execute on function private.ensure_conversation_key(uuid, text) to authenticated;
