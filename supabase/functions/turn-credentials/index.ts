// HELBA: turn-credentials Edge Function.
//
// Mints short-lived Cloudflare Realtime TURN credentials for a call.
// The app calls it at call start (see CallService._fetchTurnIceServers
// in lib/src/calls.dart) and merges the returned iceServers into the
// peer connection's ICE servers, after the STUN entry. Without a relay
// the two phones' NATs often cannot connect directly (host/srflx only),
// so no media flows and the call drops — TURN is the fix.
//
// The long-lived TURN key must NEVER be embedded in the app: it lives
// only as Supabase secrets (TURN_KEY_ID, TURN_API_TOKEN), and this
// function exchanges it for credentials that expire after 24h
// (Cloudflare's maximum TTL is 48h). The app only ever sees the
// short-lived username/credential pair.
//
// Authentication — JWT verification stays ON (the default; see
// supabase/config.toml, which deliberately does NOT list this function
// — like send-call-push, it keeps the platform default). The gateway
// rejects requests without a valid Supabase user JWT before this
// handler runs, so only a signed-in Helba user can mint credentials.
// The app invokes it with the user's auth token (the client attaches
// the Authorization header automatically).
//
// Cloudflare API (see developers.cloudflare.com/realtime/turn):
//   POST https://rtc.live.cloudflare.com/v1/turn/keys/{TURN_KEY_ID}
//        /credentials/generate-ice-servers
//   Authorization: Bearer {TURN_API_TOKEN}
//   Body: {"ttl": 86400}
//   Response: {"iceServers": [{"urls": [...], "username": "...",
//                              "credential": "..."}]}
//
// Error contract (the app treats any non-200 as "no TURN, STUN-only"):
//   503 {"error": "turn_not_configured"} — a secret is missing.
//   502 {"error": "turn_provider_error"} — Cloudflare rejected the
//       request or could not be reached. The upstream status/body is
//       never returned (no secret leakage through an error message).
// The secrets are never logged.
//
// Required secrets (set with `supabase secrets set ...`; provided by
// the user via Secure Vault — they are NOT in this repo):
//   TURN_KEY_ID     Cloudflare Realtime TURN Key ID (public identifier)
//   TURN_API_TOKEN  Cloudflare Realtime TURN Key API Token (secret)
// Deploy: `supabase functions deploy turn-credentials`
// See README.md next to this file.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Short-lived TURN credential TTL in seconds (24h; Cloudflare's
// maximum is 48h). The app re-fetches at every call start, so a
// shorter TTL would only add latency for no benefit.
const TURN_TTL_SECONDS = 86400;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const turnKeyId = Deno.env.get("TURN_KEY_ID") ?? "";
  const turnApiToken = Deno.env.get("TURN_API_TOKEN") ?? "";
  if (!turnKeyId || !turnApiToken) {
    // Fail closed with a distinct code so the app (and the logs) can
    // tell "TURN is not configured yet" from "Cloudflare is down".
    // The secret values are never echoed back.
    console.error("turn-credentials: TURN_KEY_ID or TURN_API_TOKEN unset");
    return json({ error: "turn_not_configured" }, 503);
  }

  let upstream: Response;
  try {
    upstream = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${turnKeyId}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${turnApiToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
      },
    );
  } catch (e) {
    console.error("turn-credentials: Cloudflare request failed:", e);
    return json({ error: "turn_provider_error" }, 502);
  }
  if (!upstream.ok) {
    // Log only the status, never the body: an upstream error body
    // could echo back request details.
    console.error(
      "turn-credentials: Cloudflare rejected the request:",
      upstream.status,
    );
    return json({ error: "turn_provider_error" }, 502);
  }

  let data: unknown;
  try {
    data = await upstream.json();
  } catch {
    console.error("turn-credentials: Cloudflare returned invalid JSON");
    return json({ error: "turn_provider_error" }, 502);
  }
  const iceServers = (data as Record<string, unknown> | null)?.iceServers;
  if (!Array.isArray(iceServers)) {
    console.error("turn-credentials: Cloudflare response has no iceServers");
    return json({ error: "turn_provider_error" }, 502);
  }
  return json({ iceServers });
});
