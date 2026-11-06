-- HELBA: push trigger + tokens (migration 018).
-- Apply after 001-017. Self-contained and safe to re-run.
--
-- Addresses audit findings F30/F31 (child-D report #5, #10, #22):
--   (a) Clients can now delete their own push tokens
--       (push_tokens_delete_own + DELETE grant), so sign-out can
--       prune the token. This corrects the 011 comment that said
--       pruning is by the Edge Function only: BOTH now exist
--       (client-side delete on sign-out AND server-side pruning of
--       FIDs FCM reports invalid). The 011 file's comment is amended
--       in place as well (fresh-DB text only).
--   (b) public.notify_message_push() is rewritten:
--       - system messages no longer fire a push and no plaintext
--         body is shipped for them (early return);
--       - the trigger secret is read from Vault secret
--         'push_trigger_secret' (same vault pattern as
--         'push_function_url') and sent as header
--         'x-helba-push-secret' alongside Content-Type;
--       - the pg_net request id is stored in public.push_send_log,
--         so failures are observable (see 021);
--       - a Vault read failure now raises a NOTICE instead of being
--         silently swallowed, and the database-setting fallback is
--         kept for the function URL only;
--       - a failed HTTP call still never breaks the message insert
--         (the exception handler returns NEW).
--
-- EDGE FUNCTION CONTRACT (parent sets both, no value invented
-- here): the send-message-push Edge Function must require the
-- secret — its PUSH_TRIGGER_SECRET env var must equal the Vault
-- secret 'push_trigger_secret' — and reject requests whose
-- x-helba-push-secret header does not match (401). Until that is
-- deployed, pushes sent with a missing/wrong secret are rejected
-- by the function and the failure is visible in push_send_log /
-- net._http_response (see 021), not silently lost.
--
-- push_send_log is written ONLY by this SECURITY DEFINER trigger:
-- no grants to authenticated, RLS enabled with no policies (deny
-- by default for clients). It holds no message content — only the
-- message id and the pg_net request id.

-- (a) Client-side token pruning.
drop policy if exists push_tokens_delete_own on public.push_tokens;
create policy push_tokens_delete_own on public.push_tokens
for delete to authenticated
using (user_id = (select auth.uid()));

grant delete on public.push_tokens to authenticated;

-- Internal log of push attempts (message_id -> pg_net request id).
create table if not exists public.push_send_log (
  message_id uuid not null,
  request_id bigint not null,
  created_at timestamptz not null default now()
);

create index if not exists push_send_log_request_idx
  on public.push_send_log (request_id);
create index if not exists push_send_log_created_idx
  on public.push_send_log (created_at);

alter table public.push_send_log enable row level security;
-- No policies and no grants: only the SECURITY DEFINER trigger
-- below writes this table; clients cannot read or write it.

-- (b) Rewritten push trigger.
create or replace function public.notify_message_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  function_url text;
  push_secret text;
  v_headers jsonb;
  v_request_id bigint;
begin
  -- System messages never push and never ship a body.
  if new.message_type = 'system' then
    return new;
  end if;

  -- Vault first, database setting as fallback. Either may be unset
  -- (e.g. before the parent wires the function up): then do nothing.
  -- A Vault read failure is logged visibly (NOTICE) instead of being
  -- silently swallowed; the fallback below still applies, for the
  -- function URL only.
  begin
    select decrypted_secret into function_url
    from vault.decrypted_secrets
    where name = 'push_function_url'
    limit 1;
  exception when others then
    raise notice 'helba push: failed to read Vault secret push_function_url: %', sqlerrm;
    function_url := null;
  end;
  if function_url is null or btrim(function_url) = '' then
    function_url :=
      nullif(current_setting('app.settings.push_function_url', true), '');
  end if;
  if function_url is null or btrim(function_url) = '' then
    return new;
  end if;

  -- Trigger secret for the Edge Function (Vault only; there is no
  -- database-setting fallback for a secret).
  begin
    select decrypted_secret into push_secret
    from vault.decrypted_secrets
    where name = 'push_trigger_secret'
    limit 1;
  exception when others then
    raise notice 'helba push: failed to read Vault secret push_trigger_secret: %', sqlerrm;
    push_secret := null;
  end;
  if push_secret is null or btrim(push_secret) = '' then
    raise notice 'helba push: Vault secret push_trigger_secret is not set; calling the push function without the x-helba-push-secret header (it will reject the call until PUSH_TRIGGER_SECRET is set)';
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
  else
    v_headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-helba-push-secret', push_secret
    );
  end if;

  -- A failed HTTP call must never break the message insert.
  begin
    v_request_id := net.http_post(
      url := function_url,
      headers := v_headers,
      body := jsonb_build_object(
        'conversation_id', new.conversation_id,
        'sender_id', new.sender_id,
        'message_id', new.id,
        'body', new.body,
        'message_type', new.message_type
      ),
      timeout_milliseconds := 5000
    );
    -- Record the request id so failures are observable (021).
    -- A logging failure must not break the message insert either.
    begin
      insert into public.push_send_log (message_id, request_id)
      values (new.id, v_request_id);
    exception when others then
      raise notice 'helba push: failed to log push request id for message %: %', new.id, sqlerrm;
    end;
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
