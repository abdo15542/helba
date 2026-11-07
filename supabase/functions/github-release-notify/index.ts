// HELBA: github-release-notify Edge Function.
//
// Receives a GitHub "release published" webhook and pushes an FCM
// notification to EVERY registered device (all rows of `push_tokens`)
// so the user learns about a new build the moment it is published —
// instead of waiting for the app's throttled in-app update check
// (lib/src/app_update.dart, once per hour). Tapping the notification
// opens the app and the inbox shows the update dialog for that build
// (see lib/src/push.dart `parseAppUpdatePushData` and lib/src/inbox.dart
// `_checkForUpdate`).
//
// SECURITY — fail closed on the signature, never on a 5xx:
// GitHub signs every webhook delivery with HMAC-SHA256 over the RAW
// request body, using the shared secret, and sends it as the
// `X-Hub-Signature-256: sha256=<hex>` header. This function verifies
// that signature BEFORE doing anything (and before parsing the JSON,
// because the HMAC is over the raw bytes, not a re-serialisation).
// A missing/unset secret or a mismatched signature returns HTTP 401
// and sends nothing — so a misconfigured webhook secret is visible in
// GitHub's delivery log instead of silently dropping every release.
// Every OTHER problem (not a release event, not a build tag, FCM not
// configured) returns HTTP 200, so GitHub does not retry forever on a
// misconfiguration; only the signature failure is a 401.
//
// VERIFY_JWT: GitHub sends no Supabase user JWT, so the platform would
// reject every webhook call with 401 at the gateway (same as the
// send-message-push 401 of 2026-11-06). The fix is
// `supabase/config.toml`:
//   [functions.github-release-notify]
//   verify_jwt = false
// — plus a REDEPLOY, or the setting never takes effect. The HMAC check
// below is the authentication, so turning the platform check off is
// safe. Do NOT turn verify_jwt off for send-call-push.
//
// Required secrets (set with `supabase secrets set ...`):
//   FCM_SERVICE_ACCOUNT      full Firebase service-account JSON (string)
//   SUPABASE_URL             e.g. https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY
//   GITHUB_WEBHOOK_SECRET    shared secret, set to the SAME value in the
//                            GitHub webhook (Settings → Webhooks → the
//                            Helba webhook → Secret). If it is unset
//                            here, NO request passes (fail closed, 401).
// Deploy: `supabase functions deploy github-release-notify`
// Then create the GitHub webhook (parent's job — see README.md next to
// this file): repo Settings → Webhooks → Add webhook, Payload URL
// https://<project-ref>.supabase.co/functions/v1/github-release-notify,
// Content type application/json, Secret = GITHUB_WEBHOOK_SECRET,
// "Let me select individual events" → releases ONLY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.119.0";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

// Max FCM sends in flight at once (bounded concurrency, same as
// send-message-push).
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

/// Parses a release tag of the form `build-<N>` (e.g. `build-137`) to
/// its build number. Returns null for anything else. Mirrors
/// `parseBuildTag` in lib/src/app_update.dart — the two must agree, or
/// the function would notify about a tag the app cannot install.
function parseBuildTag(tag: unknown): number | null {
  if (typeof tag !== "string") return null;
  const match = /^build-(\d+)$/.exec(tag.trim());
  if (match === null) return null;
  const n = Number(match[1]);
  return Number.isSafeInteger(n) ? n : null;
}

/// HMAC-SHA256 of [data] with [secret], as a lowercase hex string.
/// Uses Web Crypto (available in Deno Edge Functions).
async function hmacSha256Hex(
  secret: string,
  data: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  return [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Constant-time string comparison, so a signature check does not leak
/// how many leading characters matched. Returns false on any length
/// mismatch (a wrong-length signature is never valid).
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/// Cached Google OAuth2 access token, per isolate (module-level `let` is
/// fine for Deno Deploy / Edge Functions: each isolate keeps its own
/// cache, and a stale cache can only cost one extra mint). The token is
/// minted with a 60-minute expiry and reused while it has more than 5
/// minutes of life left, so a release does not mint a token per FID.
/// Same pattern as send-message-push.
let cachedAccessToken: string | null = null;
let cachedAccessTokenExpiresAt = 0; // epoch seconds

function clearAccessTokenCache(): void {
  cachedAccessToken = null;
  cachedAccessTokenExpiresAt = 0;
}

/// Mints a Google OAuth2 access token from the Firebase service account
/// (JWT RS256, firebase.messaging scope). Returns null on any failure.
/// Same as send-message-push.
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
/// Same as send-message-push.
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
/// body still counts), so no JSON parsing is attempted here. Same as
/// send-message-push.
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

  // Authentication FIRST, before any config check or body parsing.
  // GitHub signs the raw body; a missing secret or a bad signature
  // returns 401 (never 200) so the misconfiguration is visible in
  // GitHub's webhook delivery log instead of silently dropping every
  // release. Fail closed: if the secret is not configured in this
  // environment, NO request may pass.
  const webhookSecret = Deno.env.get("GITHUB_WEBHOOK_SECRET") ?? "";
  if (!webhookSecret) {
    console.error(
      "github-release-notify: GITHUB_WEBHOOK_SECRET not configured in " +
        "the function environment; rejecting (deploy after setting " +
        "the secret)",
    );
    return json({ ok: false, error: "webhook secret not configured" }, 401);
  }
  // The HMAC is over the RAW body, so the body must be read as text
  // first and only then parsed as JSON — re-serialising a parsed
  // payload would change the bytes and break the signature.
  let rawBody = "";
  try {
    rawBody = await req.text();
  } catch {
    return json({ ok: false, error: "unreadable body" });
  }
  const signature = req.headers.get("x-hub-signature-256") ?? "";
  const expected = "sha256=" + await hmacSha256Hex(webhookSecret, rawBody);
  if (!signature || !timingSafeEqual(signature, expected)) {
    console.error(
      "github-release-notify: unauthorized (X-Hub-Signature-256 " +
        "missing or does not match GITHUB_WEBHOOK_SECRET)",
    );
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  if (req.method !== "POST") {
    return json({ ok: false, error: "method not allowed" }, 405);
  }

  // Only a published, non-draft, non-prerelease release notifies.
  // Anything else (ping, edited, unpublished, deleted, prerelease,
  // draft, any non-release event) is acknowledged and ignored — GitHub
  // must see 200 so it does not retry a delivery we deliberately
  // skipped.
  const event = req.headers.get("x-github-event") ?? "";
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return json({ ok: false, error: "invalid json" });
  }
  const release = payload.release as Record<string, unknown> | undefined;
  const isReleasePublished = event === "release" &&
    payload.action === "published" &&
    release !== undefined &&
    release.draft === false &&
    release.prerelease === false;
  if (!isReleasePublished) {
    console.log(
      `github-release-notify ignored event=${event} ` +
        `action=${String(payload.action ?? "")}`,
    );
    return json({ ok: true, ignored: true });
  }

  const build = parseBuildTag(release.tag_name);
  if (build === null) {
    console.log(
      `github-release-notify ignored tag=${String(release.tag_name ?? "")} ` +
        "(not a build tag)",
    );
    return json({ ok: false, error: "not a build tag" });
  }

  const fcmSecret = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!fcmSecret || !supabaseUrl || !serviceRoleKey) {
    // Deliberately 200, never 500: GitHub must not retry a delivery
    // that can never succeed while the function is misconfigured.
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

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // Recipients: EVERY registered device (all push_tokens rows,
  // deduped). Unlike a message push there is no sender to exclude —
  // every install gets the update notice.
  let fids: string[] = [];
  try {
    const { data, error } = await supabase
      .from("push_tokens")
      .select("token");
    if (error) throw error;
    fids = [...new Set((data ?? []).map((r) => String(r.token)))];
  } catch (e) {
    console.error("Failed to load push tokens:", e);
    return json({ ok: false, error: "tokens lookup failed" });
  }
  if (fids.length === 0) {
    console.log(
      `github-release-notify build=${build} sent=0 failed=0 ` +
        "reason=no_tokens",
    );
    return json({ ok: true, sent: 0, failed: 0 });
  }

  let accessToken = await getAccessToken(serviceAccount);
  if (!accessToken) {
    console.error(
      `github-release-notify build=${build}: OAuth token mint failed`,
    );
    return json({ ok: false, error: "oauth failed" });
  }

  const notificationTitle = "تحديث جديد متاح";
  const notificationBody = `الإصدار ${build} من هلبة جاهز — اضغط للتحميل`;

  // One FCM send for one FID. Returns true when FCM accepted it.
  // On a 401 from FCM the cached token is cleared and the send is
  // retried once with a fresh token. A dead (unregistered) token is
  // pruned from `push_tokens` and still counts as failed. Same as
  // send-message-push.
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
              notification: {
                title: notificationTitle,
                body: notificationBody,
              },
              android: {
                priority: "high",
                notification: {
                  channel_id: "helba_messages",
                  click_action: "FLUTTER_NOTIFICATION_CLICK",
                },
              },
              data: {
                type: "app_update",
                build: String(build),
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
  // Observability (same pattern as send-message-push): log the outcome
  // on every invocation, including sent: 0 with the reason — a 200 with
  // no indication of whether anything was sent is not diagnosable.
  const reason = sent === 0 ? "all_failed" : undefined;
  console.log(
    `github-release-notify build=${build} sent=${sent} failed=${failed}` +
      (reason ? ` reason=${reason}` : ""),
  );
  return json({ ok: true, sent, failed });
});
