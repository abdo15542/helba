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
// Required secrets (set with `supabase secrets set ...`):
//   FCM_SERVICE_ACCOUNT      full Firebase service-account JSON (string)
//   SUPABASE_URL             e.g. https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY
// Deploy: `supabase functions deploy send-message-push`
// Then point the trigger at it: set the database secret `push_function_url`
// (Vault) or `alter database ... set "app.settings.push_function_url"` to
// the deployed function URL. See README.md next to this file.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

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

  const accessToken = await mintAccessToken(serviceAccount);
  if (!accessToken) return json({ ok: false, error: "oauth failed" });

  const notificationBody = preview(body, messageType);
  let sent = 0;
  let failed = 0;
  for (const fid of fids) {
    try {
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              fid,
              notification: { title: senderName, body: notificationBody },
              data: {
                conversation_id: conversationId,
                type: "message",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              },
            },
          }),
        },
      );
      if (res.ok) {
        sent++;
      } else {
        failed++;
        console.error(
          `FCM send failed for FID ${fid.slice(0, 12)}…:`,
          res.status,
          await res.text(),
        );
      }
    } catch (e) {
      failed++;
      console.error(`FCM send error for FID ${fid.slice(0, 12)}…:`, e);
    }
  }
  return json({ ok: true, sent, failed });
});
