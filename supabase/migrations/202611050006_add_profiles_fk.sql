-- 006: let PostgREST resolve the profiles embed through conversation_members.
--
-- The inbox and chat screens embed profiles through conversation_members
-- (conversation_members(user_id, profiles(display_name, username))), but
-- conversation_members.user_id only had a foreign key to auth.users.
-- PostgREST needs an explicit foreign key to public.profiles to resolve
-- that embed, otherwise every inbox load fails with PGRST200
-- ("Could not find a relationship between 'conversation_members' and
-- 'profiles' in the schema cache").
--
-- Every auth user gets a profiles row from the handle_new_auth_user
-- trigger, so user_id values already match profiles.id; the constraint
-- only makes that relationship explicit for PostgREST (and enforces it).
--
-- NOTE (2026-11-06): this migration already ran live; the DO block
-- below only matters for fresh databases. It is now idempotent (a
-- pg_constraint guard skips re-adding) and orphan-safe (member rows
-- whose user has no profiles row are deleted first — otherwise
-- adding the FK fails validation and blocks every later migration).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'conversation_members_user_id_profiles_fk'
      and conrelid = 'public.conversation_members'::regclass
  ) then
    delete from public.conversation_members m
    where not exists (select 1 from public.profiles p where p.id = m.user_id);
    alter table public.conversation_members
      add constraint conversation_members_user_id_profiles_fk
      foreign key (user_id) references public.profiles(id) on delete cascade;
  end if;
end
$$;
