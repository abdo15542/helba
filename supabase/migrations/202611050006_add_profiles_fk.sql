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
alter table public.conversation_members
  add constraint conversation_members_user_id_profiles_fk
  foreign key (user_id) references public.profiles(id) on delete cascade;
