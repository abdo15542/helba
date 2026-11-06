-- HELBA: push observability cron (migration 021).
-- Apply after 001-020. Self-contained and safe to re-run.
--
-- Addresses audit finding F63, trigger part (child-D report #22):
-- the push trigger (011, rewritten in 018) used to be
-- fire-and-forget — its pg_net request id was discarded, so DNS
-- failures, 4xx/5xx and OAuth failures were invisible, and
-- net._http_response grows unboundedly. Migration 018 now stores
-- every request id in public.push_send_log; this migration adds the
-- hourly job that (a) reports failures, (b) prunes old rows.
--
-- ASSUMPTIONS about pg_net's net._http_response (reported, not
-- verified live): columns id (bigint), status_code (int),
-- error (text), created (timestamptz). The helper function checks
-- information_schema for the table AND those four columns first and
-- does nothing (with a NOTICE) when they are absent or different,
-- so a pg_net schema change can never break the job — it just skips
-- the purge. If the columns differ on the live project, adjust the
-- column list in public.purge_push_observability() to match.
--
-- What the job does, hourly:
--   * Raises a NOTICE (visible in Postgres logs / cron job run
--     details) for any net._http_response row with a non-null error
--     or status_code >= 400 joined to push_send_log — one summary
--     notice with the count and up to 5 recent message ids, not one
--     notice per row.
--   * Deletes net._http_response rows older than 7 days.
--   * Deletes push_send_log rows older than 7 days, but ONLY rows
--     whose request id no longer exists in net._http_response or
--     whose net row is older than 1 hour — fresh unanswered rows
--     are never deleted.
--
-- NOTE: pg_cron availability on the live project is UNCONFIRMED
-- (same as 017/019). The job is only scheduled when pg_cron exists
-- and no job of the same name exists yet; otherwise the migration
-- logs a NOTICE and continues. The parent must verify the job
-- exists after applying:
--   select jobname, schedule from cron.job
--   where jobname = 'helba-purge-push-observability';
-- The job runs with the scheduling role's privileges; that role
-- must be able to delete from net._http_response (it can when the
-- migration is applied from the Supabase dashboard as postgres).

create or replace function public.purge_push_observability()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_col_count integer;
  v_fail_count integer := 0;
  v_sample text;
  v_deleted_net integer := 0;
  v_deleted_log integer := 0;
begin
  -- Defensive: tolerate a missing or different pg_net schema.
  -- The statements below reference net._http_response, so they are
  -- only reached after this guard passes (PL/pgSQL plans each
  -- statement lazily, on first execution).
  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'net' and table_name = '_http_response'
  ) then
    raise notice 'helba push observability: net._http_response does not exist; skipping purge';
    return;
  end if;

  select count(*) into v_col_count
  from information_schema.columns
  where table_schema = 'net'
    and table_name = '_http_response'
    and column_name in ('id', 'status_code', 'error', 'created');
  if v_col_count < 4 then
    raise notice 'helba push observability: net._http_response is missing expected columns (id, status_code, error, created); skipping purge';
    return;
  end if;

  -- Report failures: error set, or HTTP status >= 400, joined to
  -- the log so the message ids are identifiable.
  select count(*) into v_fail_count
  from net._http_response r
  join public.push_send_log l on l.request_id = r.id
  where r.error is not null or r.status_code >= 400;
  if v_fail_count > 0 then
    select string_agg(l.message_id::text, ', ') into v_sample
    from (
      select l.message_id
      from net._http_response r
      join public.push_send_log l on l.request_id = r.id
      where r.error is not null or r.status_code >= 400
      order by r.created desc
      limit 5
    ) l;
    raise notice 'helba push observability: % failed push HTTP responses (error or status >= 400); recent message_ids: %', v_fail_count, v_sample;
  end if;

  delete from net._http_response
  where created < now() - interval '7 days';
  get diagnostics v_deleted_net = row_count;

  delete from public.push_send_log l
  where l.created_at < now() - interval '7 days'
    and (
      not exists (
        select 1 from net._http_response r where r.id = l.request_id
      )
      or exists (
        select 1 from net._http_response r
        where r.id = l.request_id
          and r.created < now() - interval '1 hour'
      )
    );
  get diagnostics v_deleted_log = row_count;

  raise notice 'helba push observability: purged % net._http_response rows and % push_send_log rows older than 7 days', v_deleted_net, v_deleted_log;
end;
$$;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron extension not installed; skipping job helba-purge-push-observability (verify manually after applying)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'helba-purge-push-observability') then
    raise notice 'pg_cron job helba-purge-push-observability already exists; skipping';
    return;
  end if;
  perform cron.schedule(
    'helba-purge-push-observability',
    '0 * * * *',
    $cmd$select public.purge_push_observability()$cmd$
  );
end
$do$;
