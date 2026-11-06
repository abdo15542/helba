// HELBA: send-message-push Edge Function.
//
// Called by the `messages_notify_push` trigger (migration 011) on every
// new message. Sends one FCM HTTP v1 message per registered device of the
// conversation members (excluding the sender), addressed by Firebase
// Installation ID (FID) via the `message.fid` field — the current FCM
// API; the old `message.token` field is deprecated. The app stores each
// install's FID in `push_tokens.token` (see lib/src/push.dart).
//
// This function NEVER returns 5xx for a configuration problem: a missing
// secret or a bad request returns HTTP 200 with {ok:false, ...}, because
// the database trigger must never see a failure (and a failed HTTP call
// must never break a message insert). Per-token FCM failures are logged
// and counted, never fatal.
//
// The ONE exception is authentication: a request without the trigger
// secret returns HTTP 401. Auth failure must be visible in the trigger's
// pg_net response log, not silent, so a misconfigured secret is noticed
// instead of silently dropping every push.
//
// Required secrets (set with `supabase secrets set ...`):
//   FCM_SERVICE_ACCOUNT      full Firebase service-account JSON (string)
//   SUPABASE_URL             e.g. https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY
//   PUSH_TRIGGER_SECRET      shared secret the trigger sends on every call
//                            as the `x-helba-push-secret` header. The
//                            parent must set the SAME value in both places:
//                              supabase secrets set PUSH_TRIGGER_SECRET='...'
//                            and the Vault secret 'push_trigger_secret'
//                            (which the trigger reads). If it is unset here,
//                            NO request passes (fail closed, 401).
// Deploy: `supabase functions deploy send-message-push`
// Then point the trigger at it: set the database secret `push_function_url`
// (Vault) or `alter database ... set "app.settings.push_function_url"` to
// the deployed function URL. See README.md next to this file.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.119.0";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

// Max FCM sends in flight at once (bounded concurrency, see below).
const SEND_CONCURRENCY = 5;
// How early (seconds) before expiry the cached OAuth token is refreshed.
const TOKEN_REFRESH_EARLY_SECONDS = 300;
// OAuth tokens are minted with a 60-minute expiry (see mintAccessToken).
const TOKEN_TTL_SECONDS = 60 * 60;

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

/// Arabic preview for a notification body, mirroring
/// buildNotificationBody() in lib/src/push.dart.
function preview(body: string, messageType: string): string {
  switch (messageType) {
    case "image":
      return "صورة";
    case "video":
      return "فيديو";
    case "audio":
      return "ملف صوتي";
    case "file":
      return "ملف";
    default:
      break;
  }
  const text = (body ?? "").trim();
  if (text === "") return "رسالة جديدة";
  return text.length <= 100 ? text : `${text.slice(0, 100)}…`;
}

/// Cached Google OAuth2 access token, per isolate (module-level `let` is
/// fine for Deno Deploy / Edge Functions: each isolate keeps its own
/// cache, and a stale cache can only cost one extra mint). The token is
/// minted with a 60-minute expiry and reused while it has more than 5
/// minutes of life left, so a busy conversation does not mint a token
/// per message (or per FID).
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // F31 — Authentication, before any config check. The trigger sends
  // `x-helba-push-secret` on every call; direct callers without it get
  // 401. Fail closed: if the secret is not configured in this
  // environment, NO request may pass — return 401 (not 200) so the
  // misconfiguration shows up in the trigger's pg_net response log
  // instead of silently looking like a working function.
  const pushSecret = Deno.env.get("PUSH_TRIGGER_SECRET") ?? "";
  if (!pushSecret) {
    return json({ ok: false, error: "push secret not configured" }, 401);
  }
  if (req.headers.get("x-helba-push-secret") !== pushSecret) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  if (req.method !== "POST") {
    return json({ ok: false, error: "method not allowed" }, 405);
  }

  const fcmSecret = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!fcmSecret || !supabaseUrl || !serviceRoleKey) {
    // Deliberately 200, never 500: the trigger must not see failures.
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
  const conversationId = String(payload.conversation_id ?? "");
  const senderId = String(payload.sender_id ?? "");
  const body = String(payload.body ?? "");
  const messageType = String(payload.message_type ?? "text");
  if (!conversationId || !senderId) {
    return json({ ok: false, error: "missing conversation_id or sender_id" });
  }

  // F63 — Defensive system-message guard (defence in depth: the trigger
  // also guards). A system message must never ship a plaintext body to
  // FCM, even on a direct call.
  if (messageType === "system") {
    return json({ ok: true, sent: 0, failed: 0 });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // Sender display name for the notification title.
  let senderName = "هلبة";
  try {
    const { data } = await supabase
      .from("profiles")
      .select("display_name,username")
      .eq("id", senderId)
      .maybeSingle();
    const display = String(data?.display_name ?? "").trim();
    const username = String(data?.username ?? "").trim();
    if (display) senderName = display;
    else if (username) senderName = `@${username}`;
  } catch (e) {
    console.error("Failed to load sender profile:", e);
  }

  // Recipients: conversation members except the sender.
  let memberIds: string[] = [];
  try {
    const { data, error } = await supabase
      .from("conversation_members")
      .select("user_id")
      .eq("conversation_id", conversationId)
      .neq("user_id", senderId);
    if (error) throw error;
    memberIds = (data ?? []).map((r) => String(r.user_id));
  } catch (e) {
    console.error("Failed to load conversation members:", e);
    return json({ ok: false, error: "members lookup failed" });
  }
  if (memberIds.length === 0) return json({ ok: true, sent: 0, failed: 0 });

  let fids: string[] = [];
  try {
    const { data, error } = await supabase
      .from("push_tokens")
      .select("token")
      .in("user_id", memberIds);
    if (error) throw error;
    fids = [...new Set((data ?? []).map((r) => String(r.token)))];
  } catch (e) {
    console.error("Failed to load push tokens:", e);
    return json({ ok: false, error: "tokens lookup failed" });
  }
  if (fids.length === 0) return json({ ok: true, sent: 0, failed: 0 });

  let accessToken = await getAccessToken(serviceAccount);
  if (!accessToken) return json({ ok: false, error: "oauth failed" });

  const notificationBody = preview(body, messageType);

  // One FCM send for one FID. Returns true when FCM accepted it.
  // On a 401 from FCM the cached token is cleared and the send is
  // retried once with a fresh token. A dead (unregistered) token is
  // pruned from `push_tokens` (F30) and still counts as failed.
  async function sendToFid(fid: string): Promise<boolean> {
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
              notification: { title: senderName, body: notificationBody },
              android: {
                priority: "high",
                notification: {
                  channel_id: "helba_messages",
                  click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
              },
              data: {
                conversation_id: conversationId,
                type: "message",
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
      if (result.ok) return true;
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
      }
      console.error(
        `FCM send failed for FID ${fid.slice(0, 12)}…:`,
        result.status,
        result.bodyText,
      );
      return false;
    } catch (e) {
      console.error(`FCM send error for FID ${fid.slice(0, 12)}…:`, e);
      return false;
    }
  }

  let sent = 0;
  let failed = 0;
  // Bounded concurrency: send in chunks of 5 via Promise.allSettled
  // instead of one sequential await per FID. Counting semantics are
  // unchanged (sent/failed per FID); a rejected send counts as failed.
  for (let i = 0; i < fids.length; i += SEND_CONCURRENCY) {
    const chunk = fids.slice(i, i + SEND_CONCURRENCY);
    const results = await Promise.allSettled(chunk.map((fid) => sendToFid(fid)));
    for (const outcome of results) {
      if (outcome.status === "fulfilled" && outcome.value) {
        sent++;
      } else {
        failed++;
        if (outcome.status === "rejected") {
          console.error("FCM send rejected:", outcome.reason);
        }
      }
    }
  }
  return json({ ok: true, sent, failed });
});
