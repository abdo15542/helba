-- HELBA: ICE candidates via the database (migration 029).
-- ICE candidates previously flowed ONLY via Supabase Realtime
-- broadcast. A peer whose Realtime subscription is down can SEND
-- broadcasts (the REST fallback) but cannot RECEIVE them, so it never
-- gets the other side's candidates and media never establishes. Both
-- sides now also store each outgoing candidate here and poll the table,
-- so media can establish without Realtime. Realtime stays the primary
-- (fast) route; this table is the fallback. Rows are never deleted
-- from the client; call_ice_candidates rows vanish with their call
-- (on delete cascade on call_id).
create table if not exists public.call_ice_candidates (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.calls(id) on delete cascade,
  from_id uuid not null references public.profiles(id) on delete cascade,
  candidate jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists call_ice_candidates_call_created_idx
  on public.call_ice_candidates (call_id, created_at);

alter table public.call_ice_candidates enable row level security;

drop policy if exists call_ice_candidates_select_participants
  on public.call_ice_candidates;
create policy call_ice_candidates_select_participants
  on public.call_ice_candidates
for select to authenticated
using (exists (
  select 1 from public.calls c
  where c.id = call_ice_candidates.call_id
    and (c.caller_id = (select auth.uid())
      or c.callee_id = (select auth.uid()))
));

drop policy if exists call_ice_candidates_insert_participant
  on public.call_ice_candidates;
create policy call_ice_candidates_insert_participant
  on public.call_ice_candidates
for insert to authenticated
with check (
  from_id = (select auth.uid())
  and exists (
    select 1 from public.calls c
    where c.id = call_ice_candidates.call_id
      and (c.caller_id = (select auth.uid())
        or c.callee_id = (select auth.uid()))
  )
);

-- No DELETE policy: candidate rows are never deleted from the client.
grant select, insert on public.call_ice_candidates to authenticated;
