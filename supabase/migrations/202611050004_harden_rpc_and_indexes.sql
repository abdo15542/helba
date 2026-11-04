-- HELBA security hardening: keep SECURITY DEFINER routines in a non-exposed schema.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_conversation_member(p_conversation uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp
as $$ select auth.uid() is not null and exists(select 1 from public.conversation_members where conversation_id=p_conversation and user_id=auth.uid()); $$;
revoke all on function private.is_conversation_member(uuid) from public,anon;
grant execute on function private.is_conversation_member(uuid) to authenticated;
create or replace function public.is_conversation_member(p_conversation uuid,p_user uuid default auth.uid())
returns boolean language sql stable security invoker set search_path=public,private,pg_temp
as $$ select p_user=auth.uid() and private.is_conversation_member(p_conversation); $$;
revoke all on function public.is_conversation_member(uuid,uuid) from public,anon;
grant execute on function public.is_conversation_member(uuid,uuid) to authenticated;

create or replace function private.create_direct_conversation(target_user uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare current_user_id uuid:=auth.uid(); new_id uuid; lock_key bigint;
begin
 if current_user_id is null or target_user is null or target_user=current_user_id then raise exception 'Invalid target user'; end if;
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
revoke all on function private.create_direct_conversation(uuid) from public,anon;
grant execute on function private.create_direct_conversation(uuid) to authenticated;
create or replace function public.create_direct_conversation(target_user uuid)
returns uuid language sql security invoker set search_path=public,private,pg_temp
as $$ select private.create_direct_conversation(target_user); $$;
revoke all on function public.create_direct_conversation(uuid) from public,anon;
grant execute on function public.create_direct_conversation(uuid) to authenticated;

create or replace function private.create_group_conversation(group_title text,member_ids uuid[])
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare actor uuid:=auth.uid(); new_id uuid; members uuid[]; member_count integer;
begin
 if actor is null then raise exception 'Authentication required'; end if;
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
revoke all on function private.create_group_conversation(text,uuid[]) from public,anon;
grant execute on function private.create_group_conversation(text,uuid[]) to authenticated;
create or replace function public.create_group_conversation(group_title text,member_ids uuid[])
returns uuid language sql security invoker set search_path=public,private,pg_temp
as $$ select private.create_group_conversation(group_title,member_ids); $$;
revoke all on function public.create_group_conversation(text,uuid[]) from public,anon;
grant execute on function public.create_group_conversation(text,uuid[]) to authenticated;

create index if not exists conversation_members_user_idx on public.conversation_members(user_id,conversation_id);
create index if not exists conversations_created_by_idx on public.conversations(created_by);
create index if not exists messages_sender_idx on public.messages(sender_id,created_at desc);
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id=(select auth.uid()));
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id=(select auth.uid())) with check (id=(select auth.uid()));
drop policy if exists messages_insert_members on public.messages;
create policy messages_insert_members on public.messages for insert to authenticated with check (sender_id=(select auth.uid()) and public.is_conversation_member(conversation_id));
