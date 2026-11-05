-- HELBA: voice/video calls (migration 010).
-- Apply after 001-009. Self-contained and safe to re-run.
-- A calls row is the call history: the caller inserts it when the call
-- starts (status 'ringing'); the callee updates it to 'ongoing' on
-- answer; whichever side ends the call writes the final status plus
-- ended_at. Signalling itself is Supabase Realtime broadcast on personal
-- channels (call:user:<id>), not this table.
-- Honest limit: calls are WebRTC peer-to-peer with STUN only
-- (stun.l.google.com:19302), no TURN server, so calls may fail on
-- strict symmetric-NAT networks.

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('voice', 'video')),
  status text not null default 'ringing'
    check (status in ('ringing', 'ongoing', 'completed', 'missed', 'declined', 'cancelled')),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create index if not exists calls_callee_started_idx
  on public.calls (callee_id, started_at desc);
create index if not exists calls_caller_started_idx
  on public.calls (caller_id, started_at desc);

alter table public.calls enable row level security;

drop policy if exists calls_select_participants on public.calls;
create policy calls_select_participants on public.calls
for select to authenticated
using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

drop policy if exists calls_insert_caller on public.calls;
create policy calls_insert_caller on public.calls
for insert to authenticated
with check (caller_id = (select auth.uid()));

drop policy if exists calls_update_participants on public.calls;
create policy calls_update_participants on public.calls
for update to authenticated
using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()))
with check (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

-- No DELETE policy: call history is never deleted from the client.
grant select, insert, update on public.calls to authenticated;
