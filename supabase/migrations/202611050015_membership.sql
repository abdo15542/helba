-- HELBA: membership RPCs + join race-safety + member_count (migration 015).
-- Apply after 001-014. Self-contained and safe to re-run.
--
-- Addresses audit findings F45, F50, F11 (child-D report #8, #15):
--   * private/public.leave_conversation, remove_member, add_member.
--     Parameter names match the client: lib/src/chat.dart calls
--     leave_conversation with {'p_conversation_id'} and remove_member
--     with {'p_conversation_id', 'p_target_user'}.
--   * join_channel / create_channel are now race-safe (insert ...
--     on conflict do nothing) and reject banned callers.
--   * conversations.member_count, backfilled and maintained by a
--     trigger on conversation_members; the app should select
--     member_count for channel directory rows instead of counting
--     members client-side.
--
-- KNOWN LIMITATION (stated, not implemented): E2E key rotation on
-- member removal is NOT implemented. A removed member keeps their
-- wrapped conversation key row and can still decrypt messages sent
-- before removal; new messages are encrypted under the same
-- conversation key, so a removed member who kept a copy of the key
-- could decrypt later messages too if they can still read them
-- (they cannot: RLS blocks reads once membership is gone). Full
-- rotation (new conversation key + re-wrap for remaining members)
-- is a separate piece of work.
--
-- Edge cases, by design:
--   * Leaving as the last member deletes the conversation row
--     (messages cascade with it). Leaving a direct conversation does
--     NOT delete it while the other member remains: it becomes a
--     single-member conversation, and starting a new direct chat
--     creates a fresh conversation (the old one keeps its history).
--   * remove_member / add_member work on group and channel
--     conversations; add_member refuses direct conversations.

-- 1. leave_conversation: caller must be a member. Deletes the
--    caller's row; if the leaver was the only admin and other members
--    remain, promotes the oldest member (by joined_at) to admin; if
--    the leaver was the last member, deletes the conversation row.
create or replace function private.leave_conversation(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_was_admin boolean;
  v_remaining integer;
  v_promote uuid;
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

  select (role = 'admin') into v_was_admin
  from public.conversation_members
  where conversation_id = p_conversation_id and user_id = actor;
  if v_was_admin is null then
    raise exception 'You are not a member of this conversation';
  end if;

  delete from public.conversation_members
  where conversation_id = p_conversation_id and user_id = actor;

  select count(*) into v_remaining
  from public.conversation_members
  where conversation_id = p_conversation_id;

  if v_remaining = 0 then
    delete from public.conversations where id = p_conversation_id;
    return;
  end if;

  if v_was_admin and not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and role = 'admin'
  ) then
    select user_id into v_promote
    from public.conversation_members
    where conversation_id = p_conversation_id
    order by joined_at asc, user_id asc
    limit 1;
    update public.conversation_members
      set role = 'admin'
      where conversation_id = p_conversation_id and user_id = v_promote;
  end if;
end;
$$;

revoke all on function private.leave_conversation(uuid) from public, anon;
grant execute on function private.leave_conversation(uuid) to authenticated;

create or replace function public.leave_conversation(p_conversation_id uuid)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.leave_conversation(p_conversation_id);
$$;

revoke all on function public.leave_conversation(uuid) from public, anon;
grant execute on function public.leave_conversation(uuid) to authenticated;

-- 2. remove_member: caller must be an admin of the conversation;
--    target must be a member; not self; not the last admin.
create or replace function private.remove_member(p_conversation_id uuid, p_target_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_target_is_admin boolean;
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
  if p_target_user is null then
    raise exception 'Target user is required';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id
      and user_id = actor and role = 'admin'
  ) then
    raise exception 'Only admins can remove members';
  end if;
  if p_target_user = actor then
    raise exception 'Admins cannot remove themselves; use leave_conversation instead';
  end if;
  select (role = 'admin') into v_target_is_admin
  from public.conversation_members
  where conversation_id = p_conversation_id and user_id = p_target_user;
  if v_target_is_admin is null then
    raise exception 'User is not a member of this conversation';
  end if;
  if v_target_is_admin and (
    select count(*) from public.conversation_members
    where conversation_id = p_conversation_id and role = 'admin'
  ) <= 1 then
    raise exception 'Cannot remove the last admin';
  end if;

  delete from public.conversation_members
  where conversation_id = p_conversation_id and user_id = p_target_user;
end;
$$;

revoke all on function private.remove_member(uuid, uuid) from public, anon;
grant execute on function private.remove_member(uuid, uuid) to authenticated;

create or replace function public.remove_member(p_conversation_id uuid, p_target_user uuid)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.remove_member(p_conversation_id, p_target_user);
$$;

revoke all on function public.remove_member(uuid, uuid) from public, anon;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- 3. add_member: caller must be an admin; target must exist in
--    profiles; group/channel only (not direct); total members
--    capped at 100.
create or replace function private.add_member(p_conversation_id uuid, p_target_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v_kind text;
  v_inserted integer;
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
  if p_target_user is null then
    raise exception 'Target user is required';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id
      and user_id = actor and role = 'admin'
  ) then
    raise exception 'Only admins can add members';
  end if;
  select kind into v_kind
  from public.conversations
  where id = p_conversation_id;
  if v_kind is null then
    raise exception 'Conversation not found';
  end if;
  if v_kind = 'direct' then
    raise exception 'Cannot add members to a direct conversation';
  end if;
  if not exists (select 1 from public.profiles where id = p_target_user) then
    raise exception 'User not found';
  end if;
  if (
    select count(*) from public.conversation_members
    where conversation_id = p_conversation_id
  ) >= 100 then
    raise exception 'Conversation is full (100 members)';
  end if;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (p_conversation_id, p_target_user, 'member')
  on conflict (conversation_id, user_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    raise exception 'User is already a member of this conversation';
  end if;
end;
$$;

revoke all on function private.add_member(uuid, uuid) from public, anon;
grant execute on function private.add_member(uuid, uuid) to authenticated;

create or replace function public.add_member(p_conversation_id uuid, p_target_user uuid)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.add_member(p_conversation_id, p_target_user);
$$;

revoke all on function public.add_member(uuid, uuid) from public, anon;
grant execute on function public.add_member(uuid, uuid) to authenticated;

-- 4. join_channel race-safety (finding #15): the exists-check +
--    bare insert let two concurrent joins collide on the PK.
--    The early return stays as the fast path; the insert is now
--    ON CONFLICT DO NOTHING, so concurrent joins collapse into one
--    row instead of a duplicate-key error. Banned callers rejected.
--    Full body copied from 008, plus the ban check.
create or replace function private.join_channel(channel_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  conv_kind text;
  conv_public boolean;
begin
  if actor is null then
    raise exception 'Authentication required';
  end if;
  if private.is_banned() then
    raise exception 'Account is banned';
  end if;
  if channel_id is null then
    raise exception 'Channel id is required';
  end if;

  select kind, is_public into conv_kind, conv_public
  from public.conversations
  where id = channel_id;

  if conv_kind is null then
    raise exception 'Channel not found';
  end if;
  if conv_kind <> 'channel' or conv_public is not true then
    raise exception 'Conversation is not a public channel';
  end if;

  -- Already a member: idempotent, return the id without error.
  if exists (
    select 1 from public.conversation_members
    where conversation_id = channel_id and user_id = actor
  ) then
    return channel_id;
  end if;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (channel_id, actor, 'member')
  on conflict (conversation_id, user_id) do nothing;

  return channel_id;
end;
$$;

-- 5. create_channel: same race-safety for its member insert, plus
--    the ban check. Full body copied from 008, otherwise unchanged.
create or replace function private.create_channel(
  channel_title text,
  member_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  new_id uuid;
  members uuid[];
  member_count integer;
begin
  if actor is null then
    raise exception 'Authentication required';
  end if;

  if private.is_banned() then
    raise exception 'Account is banned';
  end if;

  if channel_title is null
    or length(trim(channel_title)) < 2
    or length(trim(channel_title)) > 80 then
    raise exception 'Channel title must be between 2 and 80 characters';
  end if;

  select coalesce(array_agg(distinct requested.id), '{}'::uuid[])
    into members
  from unnest(coalesce(member_ids, '{}'::uuid[])) as requested(id)
  where requested.id is not null and requested.id <> actor;

  member_count := coalesce(array_length(members, 1), 0);
  if member_count < 1 or member_count > 99 then
    raise exception 'A channel must have between 2 and 100 members including its creator';
  end if;

  if exists (
    select 1
    from unnest(members) as requested(id)
    left join public.profiles p on p.id = requested.id
    where p.id is null
  ) then
    raise exception 'One or more users do not exist';
  end if;

  insert into public.conversations(kind, title, is_public, created_by)
  values ('channel', trim(channel_title), true, actor)
  returning id into new_id;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (new_id, actor, 'admin');

  insert into public.conversation_members(conversation_id, user_id, role)
  select new_id, requested.id, 'member'
  from unnest(members) as requested(id)
  on conflict (conversation_id, user_id) do nothing;

  return new_id;
end;
$$;

-- 6. member_count (finding #11): denormalised count on
--    conversations, backfilled from conversation_members and kept
--    in sync by a trigger. The app should select member_count for
--    channel directory rows instead of counting members client-side.
alter table public.conversations
  add column if not exists member_count integer not null default 0;

update public.conversations c
set member_count = (
  select count(*) from public.conversation_members m
  where m.conversation_id = c.id
);

create or replace function public.maintain_conversation_member_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    update public.conversations
      set member_count = member_count + 1
      where id = NEW.conversation_id;
    return NEW;
  elsif TG_OP = 'DELETE' then
    update public.conversations
      set member_count = greatest(member_count - 1, 0)
      where id = OLD.conversation_id;
    return OLD;
  end if;
  return null;
end;
$$;

drop trigger if exists conversation_members_count_sync
  on public.conversation_members;
create trigger conversation_members_count_sync
after insert or delete on public.conversation_members
for each row execute function public.maintain_conversation_member_count();
