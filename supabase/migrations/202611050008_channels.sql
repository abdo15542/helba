-- HELBA: broadcast channels (migration 008).
-- Apply after 001-007. Self-contained and safe to re-run.
-- Channels are public, broadcast-only conversations: any authenticated user
-- can list and join them, all members can read, only admins can post.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- 1. Allow 'channel' as a conversation kind.
-- The live DB may name the check constraint differently, so drop whatever
-- check constraint exists on conversations.kind, then add the new one.
do $$
declare
  r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.conversations'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%kind%'
  loop
    execute 'alter table public.conversations drop constraint '
      || quote_ident(r.conname);
  end loop;
end
$$;

alter table public.conversations
  add constraint conversations_kind_check
  check (kind in ('direct', 'group', 'channel'));

-- 2. Public flag: only public channels are listed in the directory.
alter table public.conversations
  add column if not exists is_public boolean not null default false;

create index if not exists conversations_public_channels_idx
  on public.conversations (kind, is_public);

-- 3. create_channel RPC (private SECURITY DEFINER + public thin wrapper,
-- same pattern as migration 004 for create_group_conversation).
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
  from unnest(members) as requested(id);

  return new_id;
end;
$$;

revoke all on function private.create_channel(text, uuid[]) from public, anon;
grant execute on function private.create_channel(text, uuid[]) to authenticated;

create or replace function public.create_channel(
  channel_title text,
  member_ids uuid[]
)
returns uuid
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.create_channel(channel_title, member_ids);
$$;

revoke all on function public.create_channel(text, uuid[]) from public, anon;
grant execute on function public.create_channel(text, uuid[]) to authenticated;

-- 4. join_channel RPC: idempotent join of a public channel.
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
  values (channel_id, actor, 'member');

  return channel_id;
end;
$$;

revoke all on function private.join_channel(uuid) from public, anon;
grant execute on function private.join_channel(uuid) to authenticated;

create or replace function public.join_channel(channel_id uuid)
returns uuid
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.join_channel(channel_id);
$$;

revoke all on function public.join_channel(uuid) from public, anon;
grant execute on function public.join_channel(uuid) to authenticated;

-- 5. RLS: only admins post in a channel; members read as before.
-- Reads need no change: messages_read_members already allows all members.
drop policy if exists messages_insert_members on public.messages;
create policy messages_insert_members on public.messages
for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and public.is_conversation_member(conversation_id)
  and (
    not exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id and c.kind = 'channel'
    )
    or exists (
      select 1 from public.conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = (select auth.uid())
        and m.role = 'admin'
    )
  )
);

-- 6. Public directory: non-members can list public channels (but not
-- their members — conversation_members RLS still requires membership).
drop policy if exists conversations_read_public_channels on public.conversations;
create policy conversations_read_public_channels on public.conversations
for select to authenticated
using (kind = 'channel' and is_public);
