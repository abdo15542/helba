# send-call-push — what the parent still must do

This Edge Function wakes a callee whose app is backgrounded or closed
when a call starts: it sends a high-priority FCM message (via FCM HTTP
v1) to the callee's registered devices on the dedicated `helba_calls`
Android channel. The Realtime offer only reaches a connected client,
so without this the callee never hears a call while the app is closed.
The app calls it automatically on every call start
(`CallService._sendCallPush` in `lib/src/calls.dart`, fire-and-forget —
a failure never breaks the ringing call); **until the steps below are
done, closed-app calls will not ring — and the app will not crash**.
Foreground/background calls keep working over Realtime.

## 1. Secrets — nothing new to set

This function reads the **same** secrets send-message-push already
uses, so if message push works, call push needs no new secret:

- `FCM_SERVICE_ACCOUNT` — full Firebase service-account JSON (string).
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.
- `PUSH_TRIGGER_SECRET` — the shared secret for **server** callers
  (same value as send-message-push; the Vault secret
  `push_trigger_secret` holds it). The app does **not** use this
  secret: it authenticates with its own Supabase user JWT, verified
  against Supabase Auth, and may only push its own outgoing calls.
  A user JWT for a different caller, or a call id that does not exist,
  is rejected. A call whose row is already terminal (answered /
  missed / declined / ended) returns `{ok:true, sent:0}` — the callee
  is not woken for a dead call.

If any of these is missing, the function returns HTTP 200 with
`{ok:false, error:"not configured"}` (never 5xx). A request with
neither the trigger secret nor a valid caller JWT returns HTTP 401
`{ok:false, error:"unauthorized"}`.

## 2. Deploy the function

```bash
supabase functions deploy send-call-push
```

No database trigger or migration is needed: the app calls the function
directly on call start. No Vault secret or database setting is needed
either.

## 3. How to verify end-to-end (after deploy)

1. Install the app on two devices / accounts, sign in on both (the app
   registers each device's FCM token in `push_tokens` on sign-in).
2. Close the app on device B (swipe it away), then call B from device A.
3. Device B should ring with the system ringtone and show a
   high-priority incoming-call notification titled with the caller's
   name; tapping it (or the incoming-call overlay) opens the call
   screen. Answering connects the call: the offer is re-requested
   automatically when the app was closed (the Realtime offer was lost).
4. Declining from B (or hanging up from A while B still rings) must
   end the call on both sides and stop the ringtone; the call appears
   in the «المكالمات» history on both devices with a terminal status
   (missed / declined / ended) and a duration when it was answered.
5. A direct call to the function URL with no credentials must be
   rejected: `curl -X POST <function-url> -d '{"call_id":"..."}'`
   returns HTTP 401 `{ok:false, error:"unauthorized"}`. A call with a
   valid JWT but a `caller_id` that is not the signed-in user also
   returns 401.

## Notes / limits

- The function returns HTTP 200 with `{ok:true, sent:n, failed:m}` on
  success. Per-token FCM failures are logged and counted, never fatal.
- Invalid/expired FIDs are pruned: when FCM answers 404 or reports
  `UNREGISTERED` / `registration-token-not-registered` /
  `installation-id-not-registered`, the function deletes that token row
  from `push_tokens` (service role). Sign-out also deletes the user's
  own token via the `push_tokens_delete_own` policy (Dart side).
- Data vs notification messages: the function sends a `notification`
  payload (title = caller name, body = «مكالمة صوتية واردة» /
  «مكالمة فيديو واردة») plus `data` (`type:"call"`, `call_id`,
  `caller_id`, `caller_name`, `call_type`) on channel `helba_calls`,
  so Android shows the banner even when the app is closed, and the
  tap opens the incoming call screen via `pendingIncomingCallPush`
  (see `lib/src/push.dart` and `lib/src/calls.dart`).
- The app plays the real system ringtone (looping) for incoming calls
  via `flutter_ringtone_player_advanced` (see `CallRingtone` in
  `lib/src/calls.dart`); the tray notification's own sound is only a
  fallback for the closed-app case. Outgoing calls never play a sound.
- Full-screen intent: the notification requests
  `fullScreenIntent: true`, but on Android 14+ it only takes effect
  when the app holds the `USE_FULL_SCREEN_INTENT` permission. If the
  call notification appears as a heads-up banner instead of a
  full-screen overlay, add that permission to the workflow's manifest
  patch. The ringtone + overlay still work without it.
- STUN only, no TURN (same as the rest of the call flow): calls may
  fail on some strict networks. No push is sent for a call that is
  already over — the row check is the guard.
