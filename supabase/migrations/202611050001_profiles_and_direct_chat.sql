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
-- NOTE (2026-11-06): this backfill already ran live; the DO block
-- below only matters for fresh databases. It loops per user and
-- retries with a fresh md5-suffixed username (same retry loop as
-- migration 005's trigger), so one username collision no longer
-- aborts the whole backfill.
do $$
declare
  u record;
  chosen_name text;
  chosen_username text;
  attempt integer;
  inserted_ok boolean;
begin
  for u in
    select au.id, au.email, au.raw_user_meta_data
    from auth.users au
    where not exists (select 1 from public.profiles p where p.id = au.id)
  loop
    chosen_name := coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      'مستخدم هلبة'
    );
    attempt := 0;
    inserted_ok := false;
    while attempt < 5 and not inserted_ok loop
      attempt := attempt + 1;
      if attempt = 1 then
        chosen_username := 'user_' || substr(replace(u.id::text, '-', ''), 1, 12);
      else
        chosen_username := 'user_' || substr(md5(u.id::text || attempt::text || clock_timestamp()::text), 1, 12);
      end if;
      begin
        insert into public.profiles (id, display_name, username)
        values (u.id, chosen_name, chosen_username)
        on conflict (id) do nothing;
        inserted_ok := true;
      exception when unique_violation then
        -- Username collided; retry with a fresh generated username.
        inserted_ok := false;
      end;
    end loop;
    if not inserted_ok then
      raise notice 'helba backfill: could not create profile for user % after 5 attempts (username collisions); skipping', u.id;
    end if;
  end loop;
end
$$;
