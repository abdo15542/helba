# turn-credentials

Mints short-lived Cloudflare Realtime TURN credentials for a call.
The app calls it at call start (`CallService._fetchTurnIceServers`
in `lib/src/calls.dart`) and merges the returned `iceServers` into the
peer connection after the STUN entry. Without a relay the two phones'
NATs often cannot connect directly (host/srflx only), so no media
flows and the call drops — TURN is the fix.

## Secrets

Set with `supabase secrets set ...` (values come from the user via
Secure Vault — they are NOT in this repo):

- `TURN_KEY_ID` — Cloudflare Realtime TURN Key ID (public identifier).
  Created in the Cloudflare dashboard: Realtime → TURN → Create TURN Key.
- `TURN_API_TOKEN` — Cloudflare Realtime TURN Key API Token (secret).

Until both are set the function answers
`503 {"error": "turn_not_configured"}` and the app falls back to
STUN-only (the call screen keeps its "no TURN server" warning).

## Authentication

JWT verification stays ON (the platform default — this function is
deliberately NOT listed in `supabase/config.toml`, like
`send-call-push`). Only a signed-in Helba user can mint credentials.

## Deploy

```sh
supabase functions deploy turn-credentials
```

## Response

- `200 {"iceServers": [{"urls": [...], "username": "...", "credential": "..."}]}` — credentials valid for 24h.
- `503 {"error": "turn_not_configured"}` — a secret is missing.
- `502 {"error": "turn_provider_error"}` — Cloudflare rejected the request or could not be reached.
- `405` — non-POST method.
