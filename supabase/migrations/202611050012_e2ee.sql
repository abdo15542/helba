-- HELBA: end-to-end encryption (migration 012).
-- Apply after 001-011. Self-contained and safe to re-run.
-- Simplified sender-key style scheme (per-user X25519 keypairs, one
-- AES-256-GCM conversation key per conversation, wrapped per member with
-- a key-encryption key derived from the X25519 shared secret). This is
-- NOT the Signal protocol: no forward secrecy, no ratchet, no group key
-- rotation. See lib/src/e2ee.dart for the honest limits.
--
-- messages.ciphertext / nonce hold the encrypted body; body itself keeps
-- the constant placeholder '🔒 رسالة مشفّرة' so the server never sees
-- plaintext and the message_has_content CHECK still passes.
-- Attachments (files in Storage) are NOT end-to-end encrypted by this
-- scheme — only text message bodies are.
--
-- conversation_keys rows are readable ONLY by their owner (each user
-- reads only their own wrapped row), so no member can list who else has
-- a wrapped row. Any member may INSERT a wrapped row for another member
-- (needed so the key creator can wrap for everyone, and so a later
-- sender can lazily re-wrap for a member who joined afterwards).
-- No DELETE policy: wrapped rows are never deleted from the client.

-- 1. Public keys on profiles (base64 X25519 public key bytes).
alter table public.profiles
  add column if not exists public_key text;

-- 2. Ciphertext columns on messages.
alter table public.messages
  add column if not exists ciphertext text;
alter table public.messages
  add column if not exists nonce text;
alter table public.messages
  add column if not exists is_encrypted boolean not null default false;

-- 3. Per-member wrapped conversation keys.
create table if not exists public.conversation_keys (
  conversation_id uuid not null
    references public.conversations(id) on delete cascade,
  user_id uuid not null
    references public.profiles(id) on delete cascade,
  wrapped_key text not null,
  wrapped_by uuid not null
    references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index if not exists conversation_keys_user_idx
  on public.conversation_keys (user_id);

alter table public.conversation_keys enable row level security;

drop policy if exists conversation_keys_select_own
  on public.conversation_keys;
create policy conversation_keys_select_own on public.conversation_keys
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists conversation_keys_insert_member
  on public.conversation_keys;
create policy conversation_keys_insert_member on public.conversation_keys
for insert to authenticated
with check (public.is_conversation_member(conversation_id));

drop policy if exists conversation_keys_update_own
  on public.conversation_keys;
create policy conversation_keys_update_own on public.conversation_keys
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- No DELETE policy: wrapped keys are never deleted from the client.
grant select, insert, update on public.conversation_keys to authenticated;

-- 4. Let clients publish their own public key. Migration 009 replaced the
-- broad profiles UPDATE grant with a column-level grant; without this
-- extra column the client cannot publish its public key. is_admin /
-- is_banned stay deliberately absent, as before.
grant update (public_key) on public.profiles to authenticated;

-- No change to the messages RLS policies: reads/writes are already
-- member-gated, and ciphertext is opaque to the server either way.
