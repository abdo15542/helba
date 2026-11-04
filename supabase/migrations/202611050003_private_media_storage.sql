-- HELBA private chat media storage and Realtime setup.
-- Apply after schema.sql and migrations 001/002.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'helba-chat-media',
  'helba-chat-media',
  false,
  52428800,
  array[
    'image/jpeg','image/png','image/webp','image/gif',
    'video/mp4','video/quicktime',
    'audio/mpeg','audio/mp4','audio/aac','audio/ogg','audio/wav',
    'application/pdf','text/plain',
    'application/zip'
  ]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists helba_media_read_members on storage.objects;
create policy helba_media_read_members
on storage.objects for select to authenticated
using (
  bucket_id = 'helba-chat-media'
  and array_length(storage.foldername(name), 1) >= 1
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and public.is_conversation_member(((storage.foldername(name))[1])::uuid)
);

drop policy if exists helba_media_upload_members on storage.objects;
create policy helba_media_upload_members
on storage.objects for insert to authenticated
with check (
  bucket_id = 'helba-chat-media'
  and array_length(storage.foldername(name), 1) >= 1
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and public.is_conversation_member(((storage.foldername(name))[1])::uuid)
);

drop policy if exists helba_media_delete_owner on storage.objects;
create policy helba_media_delete_owner
on storage.objects for delete to authenticated
using (
  bucket_id = 'helba-chat-media'
  and owner_id = auth.uid()::text
);

-- Add messages to Realtime only when not already published.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end
$$;
