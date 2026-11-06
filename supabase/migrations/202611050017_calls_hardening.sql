-- HELBA: calls hardening (migration 017).
-- Apply after 001-016. Self-contained and safe to re-run.
--
-- Addresses audit finding F26 (child-D report #11):
--   (a) caller_id <> callee_id CHECK constraint (self-calls were
--       allowed). The two call rows already live on the project are
--       between different users, so the constraint validates on
--       apply; if a self-call row ever appears first, this step fails
--       loudly instead of silently accepting it.
--   (b) The UPDATE grant on calls is restricted to (status,
--       ended_at): the client only ever updates those two columns.
--       Either participant can no longer rewrite caller_id,
--       callee_id, type or started_at.
--   (c) A BEFORE UPDATE trigger validates status transitions:
--       ringing -> {ongoing, missed, declined, cancelled},
--       ongoing -> {completed}; staying on the same status is
--       allowed; anything else is rejected. Changes to caller_id /
--       callee_id / type / started_at are rejected outright.
--   (d) A pg_cron job marks ringing rows older than 60s as missed,
--       so a caller who force-kills the app no longer leaves a
--       phantom ringing call in history.
--
-- NOTE: pg_cron availability on the live project is UNCONFIRMED.
-- The job is only scheduled when the pg_cron extension exists and
-- no job of the same name exists yet; otherwise the migration logs
-- a NOTICE and continues, and calls still work (the client-side
-- missed timers in lib/src/calls.dart remain the fallback). The
-- parent must verify the job exists after applying:
--   select jobname, schedule from cron.job
--   where jobname = 'helba-mark-ringing-calls-missed';

-- (a) Self-calls are impossible.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'calls_caller_ne_callee'
      and conrelid = 'public.calls'::regclass
  ) then
    alter table public.calls
      add constraint calls_caller_ne_callee check (caller_id <> callee_id);
  end if;
end
$$;

-- (b) Only status / ended_at may be updated from the client.
revoke update on public.calls from authenticated;
grant update (status, ended_at) on public.calls to authenticated;

-- (c) Status-transition + immutable-columns trigger.
create or replace function public.validate_call_transition()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if NEW.caller_id is distinct from OLD.caller_id
     or NEW.callee_id is distinct from OLD.callee_id
     or NEW.type is distinct from OLD.type
     or NEW.started_at is distinct from OLD.started_at then
    raise exception 'Call participants, type and start time cannot be changed';
  end if;

  if NEW.status is distinct from OLD.status then
    if OLD.status = 'ringing'
       and NEW.status in ('ongoing', 'missed', 'declined', 'cancelled') then
      return NEW;
    elsif OLD.status = 'ongoing' and NEW.status = 'completed' then
      return NEW;
    else
      raise exception 'Invalid call status transition from % to %', OLD.status, NEW.status;
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists calls_validate_transition on public.calls;
create trigger calls_validate_transition
before update on public.calls
for each row execute function public.validate_call_transition();

-- (d) pg_cron job: ringing older than 60s -> missed. Guarded: the
--     DO block returns early (without ever referencing cron.job)
--     when pg_cron is not installed, and skips scheduling when a job
--     of the same name already exists, so re-running is safe.
do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron extension not installed; skipping job helba-mark-ringing-calls-missed (verify manually after applying)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'helba-mark-ringing-calls-missed') then
    raise notice 'pg_cron job helba-mark-ringing-calls-missed already exists; skipping';
    return;
  end if;
  perform cron.schedule(
    'helba-mark-ringing-calls-missed',
    '* * * * *',
    $cmd$update public.calls set status = 'missed', ended_at = now() where status = 'ringing' and started_at < now() - interval '60 seconds'$cmd$
  );
end
$do$;
