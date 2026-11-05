-- HELBA: bind chat-media uploads to the uploader's own folder and make
-- automatic profile creation resilient to username collisions.
-- Apply after schema.sql and migrations 001-004.

-- (1) The upload policy used to check only conversation membership, so any
-- member could upload a file into another member's folder
-- (<conversation>/<other-user-id>/<file>). The app path is always
-- <conversation>/<own-user-id>/<file>; enforce that second segment.
drop policy if exists helba_media_upload_members on storage.objects;
create policy helba_media_upload_members
on storage.objects for insert to authenticated
with check (
  bucket_id = 'helba-chat-media'
  and array_length(storage.foldername(name), 1) >= 2
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (storage.foldername(name))[2] = auth.uid()::text
  and public.is_conversation_member(((storage.foldername(name))[1])::uuid)
);

-- (2) handle_new_auth_user() generated the username deterministically from the
-- user id, but a unique violation on username aborted the whole trigger and
-- failed sign-up. Retry with a different username instead; an existing
-- profile for the same id still ends the trigger cleanly via ON CONFLICT.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen_name text;
  chosen_username text;
  attempt integer := 0;
begin
  chosen_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'مستخدم هلبة'
  );

  loop
    attempt := attempt + 1;
    if attempt = 1 then
      chosen_username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
    else
      chosen_username := 'user_' || substr(md5(new.id::text || attempt::text || clock_timestamp()::text), 1, 12);
    end if;

    begin
      insert into public.profiles (id, display_name, username)
      values (new.id, chosen_name, chosen_username)
      on conflict (id) do nothing;
      return new;
    exception when unique_violation then
      if attempt >= 5 then
        raise;
      end if;
      -- Username collided; retry with a fresh generated username.
    end;
  end loop;
end;
$$;
