-- HELBA: stories expiry + storage policy (migration 019).
-- Apply after 001-018. Self-contained and safe to re-run.
--
-- Addresses audit findings F48/F49 (child-D report #9, #23):
--   (a) The helba-stories storage read policy now only allows media
--       whose story row is unexpired. VERIFIED from the client
--       (lib/src/stories.dart:177-178,186,405): media_url IS the bare
--       storage path '<uid>/<file>' (e.g. '<uid>/1234567890_photo.jpg'),
--       uploaded to the 'helba-stories' bucket and used verbatim for
--       createSignedUrl / remove. The policy below matches exactly
--       what the app stores; no path assumption was invented.
--   (b) A BEFORE INSERT trigger validates media_url starts with
--       auth.uid() || '/'.
--   (c) A pg_cron daily job deletes expired story rows and their
--       storage objects.
--
-- PRIVACY NOTE (conscious decision for the user): any authenticated
-- user can still read any NON-expired story — there is no
-- contacts/follow gate on stories (007's stories_select_unexpired
-- is unchanged). Expired stories are now unreadable AND deleted,
-- but non-expired stories remain visible to every signed-in user,
-- including strangers.
--
-- NOTE: pg_cron availability on the live project is UNCONFIRMED
-- (same as 017). The job is only scheduled when pg_cron exists and
-- no job of the same name exists yet; otherwise the migration logs
-- a NOTICE and continues. The parent must verify the job exists
-- after applying:
--   select jobname, schedule from cron.job
--   where jobname = 'helba-expire-stories-daily';
-- The cleanup job runs with the scheduling role's privileges; that
-- role must be able to delete from storage.objects (it can when the
-- migration is applied from the Supabase dashboard as postgres).

-- (a) Storage read policy: only media of a live (unexpired) story.
--     media_url is the bare storage path '<uid>/<file>', so
--     storage.foldername(name)[1] is the author's uid and
--     s.media_url = name is an exact match.
drop policy if exists helba_stories_read_any on storage.objects;
create policy helba_stories_read_any
on storage.objects for select to authenticated
using (bucket_id='helba-stories' and exists (select 1 from public.stories s where s.user_id::text = (storage.foldername(name))[1] and s.media_url = name and s.expires_at > now()));

-- (b) media_url must live under the author's own folder.
create or replace function public.validate_story_media_url()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if NEW.media_url is null
     or NEW.media_url not like auth.uid()::text || '/%' then
    raise exception 'Story media_url must start with your user id';
  end if;
  return NEW;
end;
$$;

drop trigger if exists stories_validate_media_url on public.stories;
create trigger stories_validate_media_url
before insert on public.stories
for each row execute function public.validate_story_media_url();

-- (c) Daily expiry cleanup: storage objects first, then the rows.
--     Wrapped in a helper function so the cron command is a single
--     statement (pg_cron command strings with multiple statements
--     are not relied upon).
create or replace function public.expire_stories()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from storage.objects
  where bucket_id = 'helba-stories'
    and name in (select media_url from public.stories where expires_at < now());
  delete from public.stories where expires_at < now();
end;
$$;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron extension not installed; skipping job helba-expire-stories-daily (verify manually after applying)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'helba-expire-stories-daily') then
    raise notice 'pg_cron job helba-expire-stories-daily already exists; skipping';
    return;
  end if;
  perform cron.schedule(
    'helba-expire-stories-daily',
    '0 3 * * *',
    $cmd$select public.expire_stories()$cmd$
  );
end
$do$;
