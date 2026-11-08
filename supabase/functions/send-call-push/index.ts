// HELBA: send-call-push Edge Function.
//
// Called by the app when a call starts (see CallService._sendCallPush in
// lib/src/calls.dart): the Realtime offer only reaches a callee whose
// app is connected, so a high-priority FCM message wakes a callee whose
// app is backgrounded or closed. The app calls it with the call id,
// callee id, caller id and call type; this function verifies the `calls`
// row and uses ITS caller_id / callee_id / type as the source of truth,
// then looks up the callee's push_tokens and sends one FCM HTTP v1
// message per device (by Firebase Installation ID via `message.fid`,
// the current FCM API) on the dedicated `helba_calls` channel.
//
// Authentication — EITHER of these (the app must never hold the
// trigger secret, and the trigger secret must never be the only way in
// for the app):
//   1. Server callers: the `x-helba-push-secret` header, the SAME
//      PUSH_TRIGGER_SECRET value send-message-push uses (shared across
//      functions; set once with `supabase secrets set`). Fail closed:
//      an empty/unset secret never matches.
//   2. App callers: a valid Supabase user JWT as
//      `Authorization: Bearer <jwt>`, verified against Supabase Auth,
//      whose user id must equal the calls row's caller_id. A user may
//      only push their own outgoing calls.
//
// The function NEVER returns 5xx for a configuration problem: a missing
// secret or a bad request returns HTTP 200 with {ok:false, ...}. The ONE
// exception is authentication: a request with neither valid credential
// returns HTTP 401, so a misconfigured caller is visible instead of
// silently dropping every call push. A call whose row is already
// terminal (answered / missed / declined / ended) returns
// {ok:true, sent:0, reason:"call_not_ringing"} — no point waking a
// callee for a dead call.
//
// OBSERVABILITY (fix 7): every invocation LOGS its outcome
// (`send-call-push call=<id> sent=N failed=M [reason=...]`) and RETURNS
// it: `{ok:true, sent, failed, reason?, details:[{fid, ok, status,
// error}]}`. `reason` is set whenever nothing was sent:
// `no_tokens` (the callee has no push_tokens row), `call_not_ringing`
// (the call row is already terminal), `all_failed` (every FCM send
// failed). The caller (the app) reads `sent`/`reason` and warns the
// caller when the callee was not woken — a 200 with no indication of
// whether anything was sent is never returned again.
//
// Required secrets (set with `supabase secrets set ...`; all already
// set for send-message-push — no new secret is needed):
//   FCM_SERVICE_ACCOUNT      full Firebase service-account JSON (string)
//   SUPABASE_URL             e.g. https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY
//   PUSH_TRIGGER_SECRET      shared secret for server callers (see
//                            send-message-push README; the Vault secret
//                            'push_trigger_secret' holds the same value)
// Deploy: `supabase functions deploy send-call-push`
// See README.md next to this file.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.119.0";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

// Max FCM sends in flight at once (bounded concurrency, see below).
const SEND_CONCURRENCY = 5;
// How early (seconds) before expiry the cached OAuth token is refreshed.
const TOKEN_REFRESH_EARLY_SECONDS = 300;
// OAuth tokens are minted with a 60-minute expiry (see mintAccessToken).
const TOKEN_TTL_SECONDS = 60 * 60;
// How long a call push stays deliverable (seconds). A call only rings
// for 60s (callRingTimeout in lib/src/calls.dart): a message delivered
// after the window would wake the callee for a call that already
// ended, so FCM must drop it instead (android.ttl + apns-expiration).
const CALL_PUSH_TTL_SECONDS = 60;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-helba-push-secret",
};

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/// Cached Google OAuth2 access token, per isolate (module-level `let` is
/// fine for Deno Deploy / Edge Functions: each isolate keeps its own
/// cache, and a stale cache can only cost one extra mint). The token is
/// minted with a 60-minute expiry and reused while it has more than 5
/// minutes of life left, so a burst of calls does not mint a token per
/// FID.
let cachedAccessToken: string | null = null;
let cachedAccessTokenExpiresAt = 0; // epoch seconds

function clearAccessTokenCache(): void {
  cachedAccessToken = null;
  cachedAccessTokenExpiresAt = 0;
}

/// Mints a Google OAuth2 access token from the Firebase service account
/// (JWT RS256, firebase.messaging scope). Returns null on any failure.
async function mintAccessToken(
  serviceAccount: Record<string, string>,
): Promise<string | null> {
  try {
    const pem = serviceAccount.private_key
      .replace(/\\n/g, "\n")
      .replace("-----BEGIN PRIVATE KEY-----", "")
      .replace("-----END PRIVATE KEY-----", "")
      .replace(/\s+/g, "");
    const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      "pkcs8",
      der,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const now = getNumericDate(0);
    const jwt = await create(
      { alg: "RS256", typ: "JWT" },
      {
        iss: serviceAccount.client_email,
        sub: serviceAccount.client_email,
        aud: "https://oauth2.googleapis.com/token",
        iat: now,
        exp: getNumericDate(60 * 60),
        scope: FCM_SCOPE,
      },
      key,
    );
    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });
    if (!res.ok) {
      console.error("OAuth token exchange failed:", res.status);
      return null;
    }
    const data = await res.json();
    return typeof data.access_token === "string" ? data.access_token : null;
  } catch (e) {
    console.error("Failed to mint OAuth token:", e);
    return null;
  }
}

/// Returns a usable OAuth access token, reusing the cached one while it
/// has more than 5 minutes of life left. Returns null on any failure.
async function getAccessToken(
  serviceAccount: Record<string, string>,
): Promise<string | null> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (
    cachedAccessToken !== null &&
    nowSeconds < cachedAccessTokenExpiresAt - TOKEN_REFRESH_EARLY_SECONDS
  ) {
    return cachedAccessToken;
  }
  const token = await mintAccessToken(serviceAccount);
  if (token !== null) {
    cachedAccessToken = token;
    cachedAccessTokenExpiresAt = nowSeconds + TOKEN_TTL_SECONDS;
  }
  return token;
}

/// True when an FCM send failure means the token is dead and must be
/// pruned from `push_tokens`: HTTP 404, or an error body naming one of
/// the unregistered-token errors. The body is checked as raw text on
/// purpose — it may be JSON, plain text, or empty (a 404 with an empty
/// body still counts), so no JSON parsing is attempted here.
function isUnregisteredError(status: number, bodyText: string): boolean {
  if (status === 404) return true;
  const lower = bodyText.toLowerCase();
  return lower.includes("unregistered") ||
    lower.includes("registration-token-not-registered") ||
    lower.includes("installation-id-not-registered");
}

/// Call statuses in which waking the callee is pointless: the call is
/// already over (or never rang). Only `ringing` (and `ongoing`, for a
/// re-send) may be pushed.
function isPushableCallStatus(status: string): boolean {
  return status === "ringing" || status === "ongoing";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "method not allowed" }, 405);
  }

  const fcmSecret = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!fcmSecret || !supabaseUrl || !serviceRoleKey) {
    // Deliberately 200, never 500: a config problem must not look like
    // a server failure to the caller.
    return json({ ok: false, error: "not configured" });
  }

  let serviceAccount: Record<string, string>;
  try {
    serviceAccount = JSON.parse(fcmSecret) as Record<string, string>;
  } catch {
    return json({ ok: false, error: "not configured" });
  }
  const projectId = serviceAccount.project_id;
  if (!projectId || !serviceAccount.client_email ||
    !serviceAccount.private_key) {
    return json({ ok: false, error: "not configured" });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "invalid json" });
  }
  const callId = String(payload.call_id ?? "");
  const callerId = String(payload.caller_id ?? "");
  const calleeId = String(payload.callee_id ?? "");
  const callType = String(payload.call_type ?? "voice");
  if (!callId || !callerId || !calleeId) {
    return json({ ok: false, error: "missing call_id, caller_id or callee_id" });
  }
  if (callType !== "voice" && callType !== "video") {
    return json({ ok: false, error: "invalid call_type" });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // --- Authentication (before any database read that depends on the
  // caller). Either the shared trigger secret, or a valid user JWT.
  // The JWT path is verified first via Supabase Auth (auth.getUser
  // validates the token against the Auth server); the returned user id
  // is then matched against the calls row below, so a user can only
  // push their OWN outgoing calls. The secret path never matches when
  // the secret is unset (fail closed).
  const pushSecret = Deno.env.get("PUSH_TRIGGER_SECRET") ?? "";
  const hasTriggerSecret = pushSecret !== "" &&
    req.headers.get("x-helba-push-secret") === pushSecret;
  let authedUserId: string | null = null;
  if (!hasTriggerSecret) {
    const authHeader = req.headers.get("authorization") ?? "";
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (match) {
      try {
        const { data, error } = await supabase.auth.getUser(match[1]);
        if (!error && data?.user) authedUserId = data.user.id;
      } catch (e) {
        console.error("Failed to verify caller JWT:", e);
      }
    }
    if (authedUserId === null) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }
  }

  // The calls row is the source of truth: the ids in the request body
  // are never trusted on their own.
  let callRow: Record<string, unknown> | null = null;
  try {
    const { data, error } = await supabase
      .from("calls")
      .select("caller_id,callee_id,type,status")
      .eq("id", callId)
      .maybeSingle();
    if (error) throw error;
    callRow = data as Record<string, unknown> | null;
  } catch (e) {
    console.error("Failed to load call row:", e);
    return json({ ok: false, error: "call lookup failed" });
  }
  if (callRow === null) {
    return json({ ok: false, error: "call not found" });
  }
  const rowCallerId = String(callRow.caller_id ?? "");
  const rowCalleeId = String(callRow.callee_id ?? "");
  const rowType = String(callRow.type ?? "voice");
  const rowStatus = String(callRow.status ?? "");
  if (rowCallerId !== callerId || rowCalleeId !== calleeId) {
    return json({ ok: false, error: "caller/callee mismatch" });
  }
  // A JWT caller may only push their own outgoing calls.
  if (authedUserId !== null && authedUserId !== rowCallerId) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }
  // Dead call: do not wake the callee for a call that already ended.
  if (!isPushableCallStatus(rowStatus)) {
    console.log(
      `send-call-push call=${callId} sent=0 failed=0 ` +
        `reason=call_not_ringing (status=${rowStatus})`,
    );
    return json({ ok: true, sent: 0, failed: 0, reason: "call_not_ringing" });
  }
  // The row's type wins over the request body's (defence in depth:
  // the app already sends the same value).
  const effectiveCallType = rowType === "video" ? "video" : "voice";

  // Caller display name for the notification title.
  let callerName = "هلبة";
  try {
    const { data } = await supabase
      .from("profiles")
      .select("display_name,username")
      .eq("id", rowCallerId)
      .maybeSingle();
    const display = String(data?.display_name ?? "").trim();
    const username = String(data?.username ?? "").trim();
    if (display) callerName = display;
    else if (username) callerName = `@${username}`;
  } catch (e) {
    console.error("Failed to load caller profile:", e);
  }

  // Recipients: the callee's registered devices.
  let fids: string[] = [];
  try {
    const { data, error } = await supabase
      .from("push_tokens")
      .select("token")
      .eq("user_id", rowCalleeId);
    if (error) throw error;
    fids = [...new Set((data ?? []).map((r) => String(r.token)))];
  } catch (e) {
    console.error("Failed to load push tokens:", e);
    return json({ ok: false, error: "tokens lookup failed" });
  }
  if (fids.length === 0) {
    console.log(
      `send-call-push call=${callId} sent=0 failed=0 reason=no_tokens`,
    );
    return json({ ok: true, sent: 0, failed: 0, reason: "no_tokens" });
  }

  let accessToken = await getAccessToken(serviceAccount);
  if (!accessToken) {
    console.error(`send-call-push call=${callId}: OAuth token mint failed`);
    return json({ ok: false, error: "oauth failed" });
  }

  const isVideo = effectiveCallType === "video";
  const notificationBody = isVideo ? "مكالمة فيديو واردة" : "مكالمة صوتية واردة";

  // One FCM send for one FID. Returns the per-FID outcome (fix 7):
  // the caller needs the counts AND the reason, not just a boolean.
  // On a 401 from FCM the cached token is cleared and the send is
  // retried once with a fresh token. A dead (unregistered) token is
  // pruned from `push_tokens` and still counts as failed.
  async function sendToFid(fid: string): Promise<
    { ok: boolean; status: number | null; error: string | null }
  > {
    const sendOnce = async (token: string) => {
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              fid,
              notification: { title: callerName, body: notificationBody },
              android: {
                priority: "high",
                // Drop the message after the 60s ring window instead
                // of waking the callee for a call that already ended.
                ttl: `${CALL_PUSH_TTL_SECONDS}s`,
                notification: {
                  channel_id: "helba_calls",
                  click_action: "FLUTTER_NOTIFICATION_CLICK",
                  sound: "default",
                },
              },
              apns: {
                headers: {
                  "apns-expiration": String(
                    Math.floor(Date.now() / 1000) + CALL_PUSH_TTL_SECONDS,
                  ),
                },
              },
              data: {
                type: "call",
                call_id: callId,
                caller_id: rowCallerId,
                caller_name: callerName,
                call_type: effectiveCallType,
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              },
            },
          }),
        },
      );
      // Read the body once, as text: it may be JSON, plain text, or
      // empty, and it is needed both for logging and for the
      // unregistered-token check below.
      return { ok: res.ok, status: res.status, bodyText: await res.text() };
    };

    try {
      let result = await sendOnce(accessToken);
      if (result.status === 401) {
        // Token may have been revoked/expired despite the cache window:
        // clear it, mint a fresh one, and retry this send exactly once.
        clearAccessTokenCache();
        const freshToken = await getAccessToken(serviceAccount);
        if (freshToken !== null) {
          accessToken = freshToken;
          result = await sendOnce(freshToken);
        }
      }
      if (result.ok) return { ok: true, status: result.status, error: null };
      if (isUnregisteredError(result.status, result.bodyText)) {
        try {
          await supabase.from("push_tokens").delete().eq("token", fid);
          console.error(
            `Pruned unregistered FID ${fid.slice(0, 12)}…:`,
            result.status,
          );
        } catch (e) {
          console.error(
            `Failed to prune unregistered FID ${fid.slice(0, 12)}…:`,
            e,
          );
        }
        return { ok: false, status: result.status, error: "unregistered" };
      }
      console.error(
        `FCM send failed for FID ${fid.slice(0, 12)}…:`,
        result.status,
        result.bodyText,
      );
      return { ok: false, status: result.status, error: `fcm_${result.status}` };
    } catch (e) {
      console.error(`FCM send error for FID ${fid.slice(0, 12)}…:`, e);
      return { ok: false, status: null, error: "send_error" };
    }
  }

  let sent = 0;
  let failed = 0;
  // Per-FID outcomes, returned to the caller (fix 7) so it can tell
  // which devices were reached. FIDs are truncated to 12 chars, the
  // same as the existing log lines — never a full token.
  const details: Array<
    { fid: string; ok: boolean; status: number | null; error: string | null }
  > = [];
  // Bounded concurrency: send in chunks of 5 via Promise.allSettled
  // instead of one sequential await per FID. Counting semantics are
  // unchanged (sent/failed per FID); a rejected send counts as failed.
  for (let i = 0; i < fids.length; i += SEND_CONCURRENCY) {
    const chunk = fids.slice(i, i + SEND_CONCURRENCY);
    const results = await Promise.allSettled(chunk.map((fid) => sendToFid(fid)));
    for (let j = 0; j < results.length; j++) {
      const outcome = results[j];
      const fid = chunk[j];
      if (outcome.status === "fulfilled") {
        details.push({ fid: `${fid.slice(0, 12)}…`, ...outcome.value });
        if (outcome.value.ok) {
          sent++;
        } else {
          failed++;
        }
      } else {
        failed++;
        console.error("FCM send rejected:", outcome.reason);
        details.push({
          fid: `${fid.slice(0, 12)}…`,
          ok: false,
          status: null,
          error: "rejected",
        });
      }
    }
  }
  // Fix 7: log AND return the outcome on every invocation, including
  // sent: 0 with the reason — never a bare 200 with no indication.
  const reason = sent === 0 ? "all_failed" : undefined;
  console.log(
    `send-call-push call=${callId} sent=${sent} failed=${failed}` +
      (reason ? ` reason=${reason}` : ""),
  );
  return json({
    ok: true,
    sent,
    failed,
    ...(reason ? { reason } : {}),
    details,
  });
});
