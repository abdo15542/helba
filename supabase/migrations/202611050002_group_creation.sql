-- HELBA: secure group creation RPC.
-- Apply after schema.sql and the profiles/direct-chat migration.

create or replace function public.create_group_conversation(
  group_title text,
  member_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
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

  if group_title is null or length(trim(group_title)) < 2 or length(trim(group_title)) > 80 then
    raise exception 'Group title must be between 2 and 80 characters';
  end if;

  select coalesce(array_agg(distinct x), '{}'::uuid[])
    into members
  from unnest(coalesce(member_ids, '{}'::uuid[])) as x
  where x is not null and x <> actor;

  member_count := coalesce(array_length(members, 1), 0);
  if member_count < 1 or member_count > 99 then
    raise exception 'A group must have between 2 and 100 members including its creator';
  end if;

  if exists (
    select 1 from unnest(members) as requested(id)
    left join public.profiles p on p.id = requested.id
    where p.id is null
  ) then
    raise exception 'One or more users do not exist';
  end if;

  insert into public.conversations(kind, title, created_by)
  values ('group', trim(group_title), actor)
  returning id into new_id;

  insert into public.conversation_members(conversation_id, user_id, role)
  values (new_id, actor, 'admin');

  insert into public.conversation_members(conversation_id, user_id, role)
  select new_id, x, 'member' from unnest(members) as x;

  return new_id;
end;
$$;

revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
