# github-release-notify — what the parent still must do

This Edge Function receives a GitHub "release published" webhook and
pushes an FCM notification to **every** registered device (all rows of
`push_tokens`) so the user learns about a new build the moment it is
published. Tapping the notification opens the app and the inbox shows
the update dialog for that build (see `lib/src/push.dart`
`parseAppUpdatePushData` and `lib/src/inbox.dart` `_checkForUpdate`).
Until the steps below are done, no release notification will arrive —
and the app will not crash: the in-app update check
(`lib/src/app_update.dart`, once per hour) is the fallback.

## 1. Set the Edge Function secrets

```bash
supabase secrets set FCM_SERVICE_ACCOUNT='<the full service-account JSON>'
supabase secrets set SUPABASE_URL='https://<project-ref>.supabase.co'
supabase secrets set SUPABASE_SERVICE_ROLE_KEY='<service_role key>'
supabase secrets set GITHUB_WEBHOOK_SECRET='<the webhook secret>'
```

`GITHUB_WEBHOOK_SECRET` is the shared secret GitHub uses to sign every
webhook delivery (HMAC-SHA256, `X-Hub-Signature-256`). Set the **same
value** in the GitHub webhook (step 3). The parent generates it — a
long random URL-safe string. **Never commit this value to the repo.**
`FCM_SERVICE_ACCOUNT`, `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
are the same values already set for `send-message-push`; if they are
already set at the project level, they do not need setting again.

## 2. Deploy the function

```bash
supabase functions deploy github-release-notify
```

### JWT verification MUST be off for this function

Supabase Edge Functions verify a user JWT on every request by default,
before the handler runs. GitHub sends **no** `Authorization` header —
it authenticates with the HMAC signature — so with the default setting
the platform rejects **every** webhook call with HTTP 401 at the
gateway and the function's own signature check never runs (the same
401 seen for `send-message-push` on 2026-11-06).

`supabase/config.toml` in this repo turns it off for this function
only:

```toml
[functions.github-release-notify]
verify_jwt = false
```

The function's own HMAC check (fail-closed 401 when
`GITHUB_WEBHOOK_SECRET` is unset or the signature mismatches) is the
authentication, so turning the platform check off is safe. **Redeploy
after adding or changing `config.toml`** — the setting only takes
effect on deploy. Do NOT turn `verify_jwt` off for `send-call-push`:
the app calls it with the caller's user JWT.

Two different 401s, two different remedies:

- 401 with an empty function log (the handler never ran): the gateway
  rejected the call — `verify_jwt` is still on. Redeploy with the
  `config.toml` above.
- 401 with `error:"webhook secret not configured"` in the response:
  the `GITHUB_WEBHOOK_SECRET` Edge Function secret was never set (or
  was set after the last deploy without redeploying). Set it, then
  redeploy.
- 401 with `error:"unauthorized"`: the GitHub webhook secret does not
  match the Edge Function secret `GITHUB_WEBHOOK_SECRET`. Make them
  the same value.

## 3. Create the GitHub webhook

In the repo (abdo15542/helba): Settings → Webhooks → Add webhook.

- **Payload URL:**
  `https://<project-ref>.supabase.co/functions/v1/github-release-notify`
- **Content type:** `application/json`
- **Secret:** the same `GITHUB_WEBHOOK_SECRET` value as step 1.
- **Which events:** "Let me select individual events" → check
  **releases** ONLY (uncheck everything else, including pushes).
- **Active:** checked.

GitHub sends a `ping` event when the webhook is created — the
function answers it with 200 `{ok:true, ignored:true}` and sends
nothing. The first real release after that triggers the notification.

## How to verify end-to-end (after 1–3)

1. Install the app on a device and sign in (the app registers the
   device's FCM token in `push_tokens` on sign-in).
2. Publish a new build (any new GitHub Release tagged `build-<N>` —
   the workflow does this on every push to main).
3. The device should show a notification "تحديث جديد متاح" with
   "الإصدار <N> من هلبة جاهز — اضغط للتحميل", even with the app
   closed. Tapping it opens the app and shows the update dialog for
   build `<N>`.
4. In GitHub (Settings → Webhooks → the webhook → Recent Deliveries)
   the release delivery should show HTTP 200 with
   `{ok:true, sent:<n>, failed:0}`.
5. A direct call without a valid signature must be rejected: calling
   the function URL with no `X-Hub-Signature-256` header (or a wrong
   one) returns HTTP 401 `{ok:false, error:"unauthorized"}`.

## Notes / limits

- Only a published, non-draft, non-prerelease release notifies.
  Drafts, prereleases, and any other event (ping, edited,
  unpublished, deleted, pushes) return 200 `{ok:true, ignored:true}`
  and send nothing. A release whose tag is not `build-<N>` returns
  200 `{ok:false, error:"not a build tag"}` and sends nothing.
- The function returns HTTP 200 with `{ok:false, error:'not
  configured'}` when a secret is missing, and `{ok:true, sent:n,
  failed:m}` on success. Per-token FCM failures are logged and
  counted, never fatal. The one exception is authentication: a call
  with a bad or missing signature returns HTTP 401, so a
  misconfigured webhook secret is visible in GitHub's delivery log
  instead of failing silently.
- Invalid/expired FIDs are pruned: when FCM answers 404 or reports
  `UNREGISTERED` / `registration-token-not-registered` /
  `installation-id-not-registered`, the function deletes that token
  row from `push_tokens` (service role).
- The notification is sent on the `helba_messages` channel with
  `click_action` `FLUTTER_NOTIFICATION_CLICK` and data
  `{type:"app_update", build:"<N>"}`; the app's tap handler turns
  that into the pending-update dialog (it does NOT open a chat).
- If the app is already open in the foreground when the push arrives,
  it shows the same notification as a local banner instead of the
  system one; tapping it has the same effect.
