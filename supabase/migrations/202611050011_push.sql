-- HELBA: push notifications (migration 011).
-- Apply after 001-010. Self-contained and safe to re-run.
-- App side (lib/src/push.dart) registers each install's Firebase
-- Installation ID (FID) in public.push_tokens and shows incoming
-- messages as local notifications.
-- A trigger on messages insert calls the send-message-push Edge Function
-- via pg_net; the trigger is guarded so a missing pg_net, a missing
-- function URL, or a failed HTTP call can NEVER break the message insert
-- (it no-ops or swallows the error and returns NEW).
-- The Edge Function itself is NOT deployed by this migration: see
-- supabase/functions/send-message-push/README.md for the Firebase project,
-- service-account secret, function URL secret and deploy steps. Until
-- those are done, no push arrives and the app keeps working without one.

create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null,
  platform text not null default 'android'
    check (platform in ('android', 'ios', 'web')),
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);

create index if not exists push_tokens_user_idx
  on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_select_own on public.push_tokens;
create policy push_tokens_select_own on public.push_tokens
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists push_tokens_insert_own on public.push_tokens;
create policy push_tokens_insert_own on public.push_tokens
for insert to authenticated
with check (user_id = (select auth.uid()));

drop policy if exists push_tokens_update_own on public.push_tokens;
create policy push_tokens_update_own on public.push_tokens
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Stale tokens are pruned BOTH ways: the Edge Function deletes FIDs
-- FCM reports invalid, and (since migration 018) the client can
-- delete its own token on sign-out (push_tokens_delete_own).
grant select, insert, update, delete on public.push_tokens to authenticated;

-- pg_net is the only way for a trigger to call the Edge Function. The
-- extension may not exist on every project, so install it best-effort:
-- a NOTICE (never an error) when it is unavailable, and the migration
-- continues — the trigger below then no-ops at runtime.
do $$
begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net extension unavailable, push trigger will no-op: %',
    sqlerrm;
end
$$;

create or replace function public.notify_message_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  function_url text;
begin
  -- Vault first, database setting as fallback. Either may be unset
  -- (e.g. before the parent wires the function up): then do nothing.
  begin
    select decrypted_secret into function_url
    from vault.decrypted_secrets
    where name = 'push_function_url'
    limit 1;
  exception when others then
    function_url := null;
  end;
  if function_url is null or btrim(function_url) = '' then
    function_url :=
      nullif(current_setting('app.settings.push_function_url', true), '');
  end if;
  if function_url is null or btrim(function_url) = '' then
    return new;
  end if;
  -- A failed HTTP call must never break the message insert.
  begin
    perform net.http_post(
      url := function_url,
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object(
        'conversation_id', new.conversation_id,
        'sender_id', new.sender_id,
        'message_id', new.id,
        'body', new.body,
        'message_type', new.message_type
      ),
      timeout_milliseconds := 5000
    );
  exception when others then
    return new;
  end;
  return new;
end;
$$;

drop trigger if exists messages_notify_push on public.messages;
create trigger messages_notify_push
after insert on public.messages
for each row execute function public.notify_message_push();
