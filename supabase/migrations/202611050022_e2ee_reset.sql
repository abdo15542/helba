-- HELBA: E2E key reset (migration 022).
-- Apply after 001-021. Self-contained and safe to re-run.
--
-- Recovery for a conversation whose key is truly lost: a wrapped row
-- that unwraps with neither the conversation-bound KEK nor the legacy
-- unbound KEK (e.g. wrapped for a key the device no longer holds).
-- No client-side heal can recover such a key, so a member may reset:
-- the server deletes every wrapped row for the conversation and the
-- client creates a fresh key (loadOrCreateConversationKey with
-- afterReset: true). Old encrypted messages in the conversation stay
-- unreadable forever — the client confirm dialog says so plainly.
-- New messages use the fresh key.
--
-- Same private SECURITY DEFINER + public thin wrapper pattern as 016.
-- The advisory lock serializes the delete against concurrent
-- ensure_conversation_key claims, so a reset cannot race a key claim
-- (a claim landing after the delete would diverge from the fresh key).

create or replace function private.reset_conversation_keys(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
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
  if not exists (
    select 1 from public.conversations where id = p_conversation_id
  ) then
    raise exception 'Conversation not found';
  end if;
  if not public.is_conversation_member(p_conversation_id) then
    raise exception 'You are not a member of this conversation';
  end if;

  -- Serialize against concurrent key claims for this conversation
  -- (see 016): the lock is held until the transaction ends.
  perform pg_advisory_xact_lock(hashtext('convkey:' || p_conversation_id::text));

  delete from public.conversation_keys
  where conversation_id = p_conversation_id;
end;
$$;

revoke all on function private.reset_conversation_keys(uuid) from public, anon;
grant execute on function private.reset_conversation_keys(uuid) to authenticated;

create or replace function public.reset_conversation_keys(p_conversation_id uuid)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.reset_conversation_keys(p_conversation_id);
$$;

revoke all on function public.reset_conversation_keys(uuid) from public, anon;
grant execute on function public.reset_conversation_keys(uuid) to authenticated;
