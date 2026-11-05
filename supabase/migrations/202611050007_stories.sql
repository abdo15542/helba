-- HELBA stories / status (24h, WhatsApp-style).
-- Apply after schema.sql and migrations 001-006.
-- Self-contained and idempotent where sensible: re-running it leaves the
-- table, bucket and policies in the intended state.

-- (1) Table: one row per story, media stored in the 'helba-stories' bucket.
create table if not exists public.stories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  media_url text not null,
  media_type text not null check (media_type in ('image', 'video')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);

create index if not exists stories_user_created_idx
  on public.stories (user_id, created_at desc);
create index if not exists stories_expires_idx
  on public.stories (expires_at);

alter table public.stories enable row level security;

-- Any authenticated user may read non-expired stories.
drop policy if exists stories_select_unexpired on public.stories;
create policy stories_select_unexpired
on public.stories for select to authenticated
using (expires_at > now());

-- Only the author may create their own stories.
drop policy if exists stories_insert_own on public.stories;
create policy stories_insert_own
on public.stories for insert to authenticated
with check (user_id = auth.uid());

-- Only the author may delete their own stories.
drop policy if exists stories_delete_own on public.stories;
create policy stories_delete_own
on public.stories for delete to authenticated
using (user_id = auth.uid());

grant select, insert, delete on public.stories to authenticated;

-- (2) Private storage bucket for story media (50 MB, images + short video).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'helba-stories',
  'helba-stories',
  false,
  52428800,
  array[
    'image/jpeg','image/png','image/webp','image/gif',
    'video/mp4','video/quicktime'
  ]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Any authenticated user may view a story's media (RLS on the stories table
-- already restricts which rows are visible; expired stories stay hidden
-- because the row cannot be read, and the signed URL is short-lived).
drop policy if exists helba_stories_read_any on storage.objects;
create policy helba_stories_read_any
on storage.objects for select to authenticated
using (bucket_id = 'helba-stories');

-- Uploads only into the uploader's own folder: <uid>/<file>.
drop policy if exists helba_stories_upload_own on storage.objects;
create policy helba_stories_upload_own
on storage.objects for insert to authenticated
with check (
  bucket_id = 'helba-stories'
  and array_length(storage.foldername(name), 1) >= 1
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Deletes only of objects the user owns.
drop policy if exists helba_stories_delete_owner on storage.objects;
create policy helba_stories_delete_owner
on storage.objects for delete to authenticated
using (
  bucket_id = 'helba-stories'
  and owner_id = auth.uid()::text
);

-- (3) Add stories to Realtime only when not already published, so the
-- inbox can refresh live; the app also refreshes on pull-to-refresh.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'stories'
  ) then
    alter publication supabase_realtime add table public.stories;
  end if;
end
$$;
