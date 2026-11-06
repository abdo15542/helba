-- HELBA: admin / ban / mute enforcement (migration 014).
-- Apply after 001-013. Self-contained and safe to re-run.
--
-- Addresses audit findings F40/F41/F42/F43 (child-D report #3, #4, #16):
--   * private.is_banned() helper. Banned users can no longer insert
--     messages, stories, reports or calls (RLS WITH CHECK), and can no
--     longer create direct/group conversations or channels, join a
--     channel, or use the leave/remove/add-member RPCs (015).
--   * muted_until on profiles + private/public.set_user_muted RPC.
--     A muted user cannot insert messages (mute is a send-block only:
--     they can still read, and can still file reports).
--   * Admins cannot ban another admin (009 only rejected self-ban).
--   * Profiles INSERT hardening: the table-level INSERT grant is
--     replaced by a column-level grant that excludes is_admin /
--     is_banned / muted_until, and the insert policy additionally
--     requires both flags to be false. The signup trigger
--     handle_new_auth_user() is SECURITY DEFINER, so it is unaffected
--     by the grant/policy change.
--
-- Note: a user banned mid-session keeps their JWT until it expires,
-- but every write is checked server-side, so the ban bites
-- immediately even without an app restart. Reads are NOT blocked:
-- a banned user can still read conversations they already belong to.
--
-- NOTE (migration 020): the RLS policies below call
-- private.is_banned() directly, so EXECUTE on that function must stay
-- granted to authenticated. Do not blanket-revoke private.* execute
-- (see 020 for why F64 was left out).

-- 1. muted_until column (before the policies/RPCs that use it).
alter table public.profiles
  add column if not exists muted_until timestamptz;

-- 2. private.is_banned() helper (same revoke/grant style as 004).
create or replace function private.is_banned() returns boolean language sql stable security definer set search_path=public,pg_temp as $$ select auth.uid() is not null and exists(select 1 from public.profiles where id=auth.uid() and is_banned); $$;
revoke all on function private.is_banned() from public, anon;
grant execute on function private.is_banned() to authenticated;

-- 3. set_user_banned: also refuse to ban another admin. (009 only
--    rejected self-ban, so two admins could ban each other and lock
--    the admin panel with no in-app unban path.)
create or replace function private.set_user_banned(
  target_user uuid,
  banned boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin
  ) then
    raise exception 'Only admins can change ban status';
  end if;
  if target_user is null then
    raise exception 'Target user is required';
  end if;
  if target_user = auth.uid() then
    raise exception 'Admins cannot ban themselves';
  end if;
  if exists (
    select 1 from public.profiles
    where id = target_user and is_admin
  ) then
    raise exception 'Cannot ban another admin';
  end if;
  update public.profiles
    set is_banned = banned, updated_at = now()
    where id = target_user;
  if not found then
    raise exception 'User not found';
  end if;
end;
$$;

revoke all on function private.set_user_banned(uuid, boolean) from public, anon;
grant execute on function private.set_user_banned(uuid, boolean) to authenticated;

-- 4. set_user_muted RPC (private SECURITY DEFINER + public thin
--    wrapper, same pattern as set_user_banned). Admin-only; refuses
--    self-mute and muting another admin, mirroring set_user_banned.
--    Parameter names are p_target_user / p_muted_until: the client
--    (lib/src/admin.dart setUserMuted) calls this RPC with exactly
--    those names. Pass p_muted_until = null to unmute.
create or replace function private.set_user_muted(
  p_target_user uuid,
  p_muted_until timestamptz
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin
  ) then
    raise exception 'Only admins can change mute status';
  end if;
  if p_target_user is null then
    raise exception 'Target user is required';
  end if;
  if p_target_user = auth.uid() then
    raise exception 'Admins cannot mute themselves';
  end if;
  if exists (
    select 1 from public.profiles
    where id = p_target_user and is_admin
  ) then
    raise exception 'Cannot mute another admin';
  end if;
  update public.profiles
    set muted_until = p_muted_until, updated_at = now()
    where id = p_target_user;
  if not found then
    raise exception 'User not found';
  end if;
end;
$$;

revoke all on function private.set_user_muted(uuid, timestamptz) from public, anon;
grant execute on function private.set_user_muted(uuid, timestamptz) to authenticated;

create or replace function public.set_user_muted(
  p_target_user uuid,
  p_muted_until timestamptz
)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.set_user_muted(p_target_user, p_muted_until);
$$;

revoke all on function public.set_user_muted(uuid, timestamptz) from public, anon;
grant execute on function public.set_user_muted(uuid, timestamptz) to authenticated;

-- 5. Banned users can no longer create direct or group conversations.
--    (Full bodies copied from 004, plus the ban check after the
--    auth check. Public wrappers are unchanged: they still call these
--    private functions.)
create or replace function private.create_direct_conversation(target_user uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare current_user_id uuid:=auth.uid(); new_id uuid; lock_key bigint;
begin
 if current_user_id is null or target_user is null or target_user=current_user_id then raise exception 'Invalid target user'; end if;
 if private.is_banned() then raise exception 'Account is banned'; end if;
 if not exists(select 1 from public.profiles where id=target_user) then raise exception 'User not found'; end if;
 lock_key:=hashtextextended(least(current_user_id::text,target_user::text)||':'||greatest(current_user_id::text,target_user::text),0);
 perform pg_advisory_xact_lock(lock_key);
 select c.id into new_id from public.conversations c
 where c.kind='direct'
 and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=current_user_id)
 and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=target_user)
 and (select count(*) from public.conversation_members m where m.conversation_id=c.id)=2
 order by c.created_at limit 1;
 if new_id is null then
  insert into public.conversations(kind,created_by) values('direct',current_user_id) returning id into new_id;
  insert into public.conversation_members(conversation_id,user_id,role) values(new_id,current_user_id,'admin'),(new_id,target_user,'member');
 end if;
 return new_id;
end; $$;

create or replace function private.create_group_conversation(group_title text,member_ids uuid[])
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare actor uuid:=auth.uid(); new_id uuid; members uuid[]; member_count integer;
begin
 if actor is null then raise exception 'Authentication required'; end if;
 if private.is_banned() then raise exception 'Account is banned'; end if;
 if group_title is null or length(trim(group_title))<2 or length(trim(group_title))>80 then raise exception 'Group title must be between 2 and 80 characters'; end if;
 select coalesce(array_agg(distinct requested.id),'{}'::uuid[]) into members from unnest(coalesce(member_ids,'{}'::uuid[])) as requested(id) where requested.id is not null and requested.id<>actor;
 member_count:=coalesce(array_length(members,1),0);
 if member_count<1 or member_count>99 then raise exception 'A group must have between 2 and 100 members including its creator'; end if;
 if exists(select 1 from unnest(members) as requested(id) left join public.profiles p on p.id=requested.id where p.id is null) then raise exception 'One or more users do not exist'; end if;
 insert into public.conversations(kind,title,created_by) values('group',trim(group_title),actor) returning id into new_id;
 insert into public.conversation_members(conversation_id,user_id,role) values(new_id,actor,'admin');
 insert into public.conversation_members(conversation_id,user_id,role) select new_id,requested.id,'member' from unnest(members) as requested(id);
 return new_id;
end; $$;

-- 6. Profiles INSERT hardening (finding #4): replace the broad
--    table-level INSERT grant with a column-level grant. is_admin /
--    is_banned / muted_until are deliberately absent, so no client
--    INSERT can set them. The signup trigger is SECURITY DEFINER and
--    is unaffected by the grant change.
revoke insert on public.profiles from authenticated;
grant insert (id, display_name, username, avatar_url, about, city, public_key, created_at, updated_at)
  on public.profiles to authenticated;

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
for insert to authenticated
with check (id=(select auth.uid()) and coalesce(is_admin,false)=false and coalesce(is_banned,false)=false);

-- 7. Ban (and, for messages, mute) enforcement in the write policies.
--    messages_insert_members preserves 008's channel-admin logic
--    verbatim; only the two new checks are appended.
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
  and not private.is_banned()
  and not exists (select 1 from public.profiles where id = (select auth.uid()) and muted_until > now())
);

drop policy if exists stories_insert_own on public.stories;
create policy stories_insert_own on public.stories
for insert to authenticated
with check (user_id = (select auth.uid()) and not private.is_banned());

drop policy if exists reports_insert_self on public.reports;
create policy reports_insert_self on public.reports
for insert to authenticated
with check (reporter_id = (select auth.uid()) and not private.is_banned());

drop policy if exists calls_insert_caller on public.calls;
create policy calls_insert_caller on public.calls
for insert to authenticated
with check (caller_id = (select auth.uid()) and not private.is_banned());
