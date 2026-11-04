-- HELBA migration: create profiles automatically and make direct-chat creation race-safe.
-- Apply after supabase/schema.sql in Supabase SQL Editor.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen_name text;
  chosen_username text;
begin
  chosen_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'مستخدم هلبة'
  );
  chosen_username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);

  insert into public.profiles (id, display_name, username)
  values (new.id, chosen_name, chosen_username)
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_helba on auth.users;
create trigger on_auth_user_created_helba
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Serialize creation for the same unordered pair to avoid duplicate direct chats
-- when both users start a conversation at nearly the same time.
create or replace function public.create_direct_conversation(target_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  new_id uuid;
  lock_key bigint;
begin
  if current_user_id is null or target_user is null or target_user = current_user_id then
    raise exception 'Invalid target user';
  end if;

  if not exists (select 1 from public.profiles where id = target_user) then
    raise exception 'User not found';
  end if;

  lock_key := hashtextextended(
    least(current_user_id::text, target_user::text) || ':' ||
    greatest(current_user_id::text, target_user::text),
    0
  );
  perform pg_advisory_xact_lock(lock_key);

  select c.id into new_id
  from public.conversations c
  where c.kind = 'direct'
    and exists (
      select 1 from public.conversation_members a
      where a.conversation_id = c.id and a.user_id = current_user_id
    )
    and exists (
      select 1 from public.conversation_members b
      where b.conversation_id = c.id and b.user_id = target_user
    )
    and (
      select count(*) from public.conversation_members m
      where m.conversation_id = c.id
    ) = 2
  order by c.created_at
  limit 1;

  if new_id is null then
    insert into public.conversations(kind, created_by)
    values ('direct', current_user_id)
    returning id into new_id;

    insert into public.conversation_members(conversation_id, user_id, role)
    values
      (new_id, current_user_id, 'admin'),
      (new_id, target_user, 'member');
  end if;

  return new_id;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.create_direct_conversation(uuid) from public, anon;
grant execute on function public.create_direct_conversation(uuid) to authenticated;

-- Existing auth users may not yet have a profile; backfill them safely.
insert into public.profiles (id, display_name, username)
select
  u.id,
  coalesce(
    nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
    'مستخدم هلبة'
  ),
  'user_' || substr(replace(u.id::text, '-', ''), 1, 12)
from auth.users u
on conflict (id) do nothing;
