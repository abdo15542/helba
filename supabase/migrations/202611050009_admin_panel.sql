-- HELBA: admin panel (migration 009).
-- Apply after 001-008. Self-contained and safe to re-run.
-- Adds is_admin / is_banned flags on profiles, a reports table with
-- admin-only reads, and admin-only RPCs for bans and stats.
-- CRITICAL: no client may promote itself. The broad client UPDATE grant on
-- profiles is replaced by a column-level grant covering only the
-- self-editable columns; is_admin / is_banned can only change through the
-- SECURITY DEFINER set_user_banned RPC (admin-checked) or a direct
-- dashboard SQL UPDATE by an operator. The very first admin must be set
-- that way: update public.profiles set is_admin = true where id = '<uuid>';

-- 1. Admin / ban flags on profiles.
alter table public.profiles
  add column if not exists is_admin boolean not null default false;
alter table public.profiles
  add column if not exists is_banned boolean not null default false;

-- 2. Reports table: users report a message / user / post; only admins read
-- them or change their status.
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('post', 'message', 'user')),
  target_id uuid not null,
  reason text not null,
  status text not null default 'pending'
    check (status in ('pending', 'reviewed', 'dismissed')),
  created_at timestamptz not null default now()
);

create index if not exists reports_status_created_idx
  on public.reports (status, created_at desc);

alter table public.reports enable row level security;

drop policy if exists reports_insert_self on public.reports;
create policy reports_insert_self on public.reports
for insert to authenticated
with check (reporter_id = (select auth.uid()));

drop policy if exists reports_select_admins on public.reports;
create policy reports_select_admins on public.reports
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.is_admin
  )
);

drop policy if exists reports_update_admins on public.reports;
create policy reports_update_admins on public.reports
for update to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.is_admin
  )
)
with check (
  exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.is_admin
  )
);

-- No DELETE policy: reports are never deleted from the client.
grant select, insert, update on public.reports to authenticated;

-- 3. Stop self-promotion: revoke the broad client UPDATE on profiles and
-- re-grant it only for the self-editable columns. is_admin / is_banned
-- are deliberately absent, so no client UPDATE can touch them.
-- (The profiles_update_self policy still limits rows to the caller's own.)
revoke update on public.profiles from authenticated;
grant update (display_name, username, avatar_url, about, city, updated_at)
  on public.profiles to authenticated;

-- 4. set_user_banned RPC (private SECURITY DEFINER + public thin wrapper,
-- same pattern as migration 004). Only admins may call it, and the check
-- runs inside the DEFINER function, so the client can never ban directly
-- through a profiles UPDATE.
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

create or replace function public.set_user_banned(
  target_user uuid,
  banned boolean
)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.set_user_banned(target_user, banned);
$$;

revoke all on function public.set_user_banned(uuid, boolean) from public, anon;
grant execute on function public.set_user_banned(uuid, boolean) to authenticated;

-- 5. admin_stats RPC (private SECURITY DEFINER + public thin wrapper).
-- One call for the admin screen's three counts; admin-only.
create or replace function private.admin_stats()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin
  ) then
    raise exception 'Only admins can view admin stats';
  end if;
  select jsonb_build_object(
    'users', (select count(*) from public.profiles),
    'conversations', (select count(*) from public.conversations),
    'messages', (select count(*) from public.messages)
  ) into result;
  return result;
end;
$$;

revoke all on function private.admin_stats() from public, anon;
grant execute on function private.admin_stats() to authenticated;

create or replace function public.admin_stats()
returns jsonb
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.admin_stats();
$$;

revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
