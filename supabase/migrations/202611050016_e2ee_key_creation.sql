-- HELBA: E2E key-creation race + plantable wrapped rows (migration 016).
-- Apply after 001-015. Self-contained and safe to re-run.
--
-- Addresses audit finding F34 (child-D report #6):
--   (a) The conversation_keys INSERT policy is tightened: the
--       inserting user must be a member, must be the wrapper
--       (wrapped_by = auth.uid()), and the row's user_id must itself
--       be a member of the conversation. A member can no longer plant
--       a wrapped row for a non-member, nor plant a row for another
--       member under someone else's name.
--   (b) New private.ensure_conversation_key RPC: the server-side,
--       locked way to claim your own wrapped row. It holds
--       pg_advisory_xact_lock(hashtext('convkey:' || conversation_id))
--       across the check-then-insert, so two members opening a fresh
--       conversation at the same time can no longer generate two
--       different conversation keys.
--
-- CLIENT CONTRACT (the client must call this FIRST to claim its own
-- row, before wrapping the key for anyone else):
--   * Call public.ensure_conversation_key(p_conversation_id,
--     p_wrapped_key) with the key you generated, wrapped for
--     yourself.
--   * If the returned key EQUALS the key you passed, you won the
--     race: unwrap it and use it for wrapping others.
--   * If the returned key DIFFERS from the key you passed, you lost
--     the race: an earlier caller already claimed the conversation
--     key. Discard your generated key, unwrap the RETURNED key, and
--     use THAT for wrapping others. Never overwrite the existing row
--     with your own key.
--   * The existing row always wins: the RPC never updates a wrapped
--     row, it only returns it. (The 013 member-based UPDATE policy
--     still allows lazy re-wraps for other members; that path is
--     unchanged.)
--
-- Note: the 016(c) fix to the 008 constraint-drop loop is an
-- in-place edit of 008's file (fresh-DB only), not in this file.

-- (a) Tighten the INSERT policy on conversation_keys.
drop policy if exists conversation_keys_insert_member
  on public.conversation_keys;
create policy conversation_keys_insert_member on public.conversation_keys
for insert to authenticated
with check (
  public.is_conversation_member(conversation_id)
  and wrapped_by = (select auth.uid())
  and exists (
    select 1 from public.conversation_members m
    where m.conversation_id = conversation_keys.conversation_id
      and m.user_id = conversation_keys.user_id
  )
);

-- (b) Locked key-claim RPC (private SECURITY DEFINER + public thin
--     wrapper, same pattern as 004).
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

  select wrapped_key into v_existing
  from public.conversation_keys
  where conversation_id = p_conversation_id and user_id = actor;

  -- Existing key wins: return it unchanged (see contract above).
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

create or replace function public.ensure_conversation_key(p_conversation_id uuid, p_wrapped_key text)
returns text
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.ensure_conversation_key(p_conversation_id, p_wrapped_key);
$$;

revoke all on function public.ensure_conversation_key(uuid, text) from public, anon;
grant execute on function public.ensure_conversation_key(uuid, text) to authenticated;
