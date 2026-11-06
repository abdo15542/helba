# send-message-push — what the parent still must do

This Edge Function sends a push notification (via FCM HTTP v1) to every
registered device of a conversation's members when a new message arrives.
The app code and the database trigger are already in place; **until the
steps below are done, no push will arrive — and the app will not crash**.
The app's push setup (`lib/src/push.dart`) silently stays disabled when
Firebase is not configured, and the trigger (`messages_notify_push`,
migration 011) no-ops when the function URL is not set.

## 1. Create the Firebase project + Android app (parent's job)

- In the Firebase console, create a project (or reuse an existing one).
- Add an Android app with the Helba package name `com.example.helba`
  (the package the app registers with — see `lib/src/push.dart`).
- No `google-services.json` is needed: the app configures Firebase
  explicitly with `FirebaseOptions` in `lib/src/push.dart`, and CI
  regenerates `android/` with `flutter create` on every build, so a
  `google-services.json` placed there would be wiped anyway. Do not add
  the Firebase Gradle plugin either — the app code needs no change.

## 2. Create a Firebase service account

- In the Firebase console (or Google Cloud console): IAM & Admin →
  Service Accounts → create one with the **Firebase Cloud Messaging**
  sender role (`firebase.messaging` scope is what the token request
  asks for), download its JSON key.
- Set it as the Edge Function secret (the whole JSON as one string):

  ```bash
  supabase secrets set FCM_SERVICE_ACCOUNT='<the full service-account JSON>'
  ```

  Never commit this JSON to the repo.

## 3. Set the remaining Edge Function + database secrets

```bash
supabase secrets set SUPABASE_URL='https://<project-ref>.supabase.co'
supabase secrets set SUPABASE_SERVICE_ROLE_KEY='<service_role key>'
supabase secrets set PUSH_TRIGGER_SECRET='<a long random value>'
```

`PUSH_TRIGGER_SECRET` is the shared secret the database trigger sends as
the `x-helba-push-secret` header on every call; without it the function
returns 401. Set the **same value** as a Vault secret the trigger reads:

```sql
select vault.create_secret(
  '<the same PUSH_TRIGGER_SECRET value>', 'push_trigger_secret');
```

The two values must match exactly, or every push call will be rejected
with 401. Never commit this value to the repo (and never commit the
service-account JSON either).

Then point the database trigger at the deployed function URL. Either
store it in Vault (preferred — the trigger reads it first):

```sql
select vault.create_secret(
  '<deployed function URL>', 'push_function_url');
```

or set the database setting (fallback the trigger also reads):

```sql
alter database postgres
  set "app.settings.push_function_url" =
  'https://<project-ref>.supabase.co/functions/v1/send-message-push';
```

## 4. Deploy the function

```bash
supabase functions deploy send-message-push
```

## 5. Apply migration 011

```bash
supabase db push
# or apply supabase/migrations/202611050011_push.sql in the SQL editor
```

This creates `public.push_tokens` and the `messages_notify_push` trigger.

## How to verify end-to-end (after 1–5)

1. Install the app on two devices / accounts, sign in on both (the app
   registers each device's FCM token in `push_tokens` on sign-in).
2. Send a message from device A while the app on device B is in the
   background or closed.
3. Device B should show a notification titled with the sender's name;
   tapping it opens that chat. Foreground messages on device B appear as
   a local notification banner instead.
4. A direct call without the trigger secret must be rejected: calling
   the function URL with no `x-helba-push-secret` header (or a wrong
   one) returns HTTP 401 `{ok:false, error:"unauthorized"}`. If it
   returns 401 with `error:"push secret not configured"`, the
   `PUSH_TRIGGER_SECRET` Edge Function secret was never set.

## Notes / limits

- The function returns HTTP 200 with `{ok:false, error:'not configured'}`
  when a secret is missing, and `{ok:true, sent:n, failed:m}` on success.
  Per-token FCM failures are logged and counted, never fatal. The one
  exception is authentication: a call without the correct
  `x-helba-push-secret` header returns HTTP 401, so a bad or missing
  trigger secret is visible in the trigger's pg_net response log
  instead of failing silently.
- Invalid/expired FIDs are now pruned: when FCM answers 404 or reports
  `UNREGISTERED` / `registration-token-not-registered` /
  `installation-id-not-registered`, the function deletes that token row
  from `push_tokens` (service role). Sign-out also deletes the user's
  own token via the `push_tokens_delete_own` policy (Dart side).
- Data-only vs notification messages: the function sends a `notification`
  payload (title/body) plus `data.conversation_id`, so Android shows the
  banner even when the app is closed, and the tap opens the chat via
  `pendingChatId` (see `lib/src/push.dart` and `lib/src/auth.dart`).
