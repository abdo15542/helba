-- HELBA schema v1: email auth + profiles + direct messaging.
-- Run in Supabase SQL Editor. Never expose service_role in the mobile app.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  username text unique,
  avatar_url text,
  about text not null default '',
  city text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('direct','group')),
  title text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('member','admin')),
  joined_at timestamptz not null default now(),
  primary key (conversation_id,user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id),
  body text,
  message_type text not null default 'text' check (message_type in ('text','image','video','audio','file','system')),
  attachment_path text,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  constraint message_has_content check (coalesce(length(body),0) > 0 or attachment_path is not null or message_type='system')
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at);

create or replace function public.is_conversation_member(p_conversation uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation and user_id = p_user
  );
$$;
revoke all on function public.is_conversation_member(uuid,uuid) from public;
grant execute on function public.is_conversation_member(uuid,uuid) to authenticated;

create or replace function public.create_direct_conversation(target_user uuid)
returns uuid language plpgsql security definer set search_path = public
as $$
declare new_id uuid;
begin
  if auth.uid() is null or target_user is null or target_user = auth.uid() then
    raise exception 'Invalid target user';
  end if;
  if not exists (select 1 from public.profiles where id = target_user) then
    raise exception 'User not found';
  end if;
  select c.id into new_id
  from public.conversations c
  where c.kind='direct'
    and exists (select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=auth.uid())
    and exists (select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=target_user)
    and (select count(*) from public.conversation_members m where m.conversation_id=c.id)=2
  limit 1;
  if new_id is null then
    insert into public.conversations(kind,created_by) values ('direct',auth.uid()) returning id into new_id;
    insert into public.conversation_members(conversation_id,user_id,role)
      values (new_id,auth.uid(),'admin'),(new_id,target_user,'member');
  end if;
  return new_id;
end;
$$;
revoke all on function public.create_direct_conversation(uuid) from public;
grant execute on function public.create_direct_conversation(uuid) to authenticated;

create or replace function public.touch_conversation()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  update public.conversations set updated_at=now() where id=new.conversation_id;
  return new;
end;
$$;
drop trigger if exists messages_touch_conversation on public.messages;
create trigger messages_touch_conversation after insert on public.messages
for each row execute function public.touch_conversation();

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists profiles_read_authenticated on public.profiles;
create policy profiles_read_authenticated on public.profiles for select to authenticated using (true);
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id=auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

drop policy if exists conversations_read_members on public.conversations;
create policy conversations_read_members on public.conversations for select to authenticated
using (public.is_conversation_member(id));
drop policy if exists members_read_same_conversation on public.conversation_members;
create policy members_read_same_conversation on public.conversation_members for select to authenticated
using (public.is_conversation_member(conversation_id));
drop policy if exists messages_read_members on public.messages;
create policy messages_read_members on public.messages for select to authenticated
using (public.is_conversation_member(conversation_id));
drop policy if exists messages_insert_members on public.messages;
create policy messages_insert_members on public.messages for insert to authenticated
with check (sender_id=auth.uid() and public.is_conversation_member(conversation_id));

-- Membership writes and conversation creation are deliberately restricted to the
-- SECURITY DEFINER RPC above; do not add client INSERT policies to membership.
revoke insert, update, delete on public.conversation_members from anon, authenticated;
grant select on public.profiles, public.conversations, public.conversation_members, public.messages to authenticated;
grant insert, update on public.profiles to authenticated;
grant insert on public.messages to authenticated;

-- Supabase Dashboard: enable Realtime for public.messages.
-- Configure email confirmation and password reset URLs in Authentication settings.
-- Device binding beyond this installation's secure storage requires server-side
-- attestation (for example Play Integrity) and an audited account-transfer flow.
