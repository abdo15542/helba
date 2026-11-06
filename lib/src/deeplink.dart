import 'dart:async';
import 'dart:io' as io;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'utils.dart';

/// The URL Supabase redirects the email-confirmation (and password-reset)
/// link to, and the app opens for. Three places must agree on it:
///  - the Android manifest carries an intent-filter for this scheme
///    (patched in by the build workflow, since android/ is generated);
///  - the Supabase dashboard lists it as the Site URL and a Redirect URL;
///  - the app passes it as emailRedirectTo / redirectTo when sending
///    those emails (see auth.dart).
const authCallbackUrl = 'helba://auth/callback';

/// True when [uri] is the app's auth callback (email confirmation,
/// password reset, magic link). The host must be `auth` and the path must
/// be `/callback`, or the link must carry an auth parameter (`code`,
/// `access_token`, `error`). Any other `helba://auth/*` path (e.g. a bare
/// `helba://auth/reset` with no parameters) is not an auth callback (M5).
bool isAuthCallback(Uri uri) {
  if (uri.scheme != 'helba' || uri.host != 'auth') return false;
  if (uri.path == '/callback') return true;
  final params = uri.queryParameters;
  return params.containsKey('code') ||
      params.containsKey('access_token') ||
      params.containsKey('error');
}

/// True when [uri] is a chat deep link: `helba://chat/<conversation_id>`
/// with exactly one path segment that is a valid UUID. A non-UUID id
/// would make PostgREST answer 400 `22P02` and the chat screen fail, so
/// it is rejected here instead of being queued (B-2).
bool isChatDeepLink(Uri uri) {
  if (uri.scheme != 'helba' || uri.host != 'chat') return false;
  final segments = uri.pathSegments;
  return segments.length == 1 && isValidUuid(segments.first);
}

/// The conversation id of a chat deep link, or null when [uri] is not
/// one (see [isChatDeepLink]).
String? chatIdFromDeepLink(Uri uri) =>
    isChatDeepLink(uri) ? uri.pathSegments.first : null;

/// A chat id waiting to be opened: set when a `helba://chat/<id>` link
/// arrives, or when a push notification is tapped (see push.dart).
/// AuthGate observes this and navigates to the chat once the user is
/// signed in and confirmed, then clears it. Same pattern as
/// [deepLinkError]: a ValueNotifier so either entry point can set it
/// without a BuildContext.
final ValueNotifier<String?> pendingChatId = ValueNotifier(null);

/// The latest error from handling an auth-callback link, if any.
/// The confirmation screen listens to this so a failed link (e.g. an
/// expired one) is explained instead of silently doing nothing.
final ValueNotifier<String?> deepLinkError = ValueNotifier(null);

bool _listening = false;

/// The live deep-link subscription, kept so concurrent links can be
/// serialised instead of racing (M4). App-lifetime: never cancelled.
StreamSubscription<Uri>? _linkSubscription;

/// True while one link is being exchanged/handled; a second link that
/// arrives in the meantime is queued and handled right after (M4).
bool _handlingLink = false;
Uri? _queuedLink;

/// Listen for the app's deep links (cold start + while running): the
/// auth-callback link (exchanged for a session) and the chat link
/// `helba://chat/<id>` (queued in [pendingChatId] for AuthGate to open).
/// Idempotent: safe to call on every app start/retry. Once the session
/// is stored, the auth-state stream moves the user into the app, so the
/// caller needs no navigation here.
Future<void> setupDeepLinks() async {
  if (_listening) return;
  _listening = true;
  final links = AppLinks();

  Future<void> handle(Uri? uri) async {
    if (uri == null) return;
    // Serialise: a second link while one is being exchanged is queued
    // instead of racing it — the race used to fail with "code already
    // used" and set a spurious error even though the first link won.
    if (_handlingLink) {
      _queuedLink = uri;
      return;
    }
    _handlingLink = true;
    try {
      if (isAuthCallback(uri)) {
        try {
          await Supabase.instance.client.auth
              .getSessionFromUrl(uri)
              .timeout(const Duration(seconds: 15));
          // Success clears any stale error (B10): without this, a link
          // that failed once kept showing its error on later screens.
          deepLinkError.value = null;
        } catch (e) {
          deepLinkError.value = deepLinkErrorMessage(e);
        }
        return;
      }
      final chatId = chatIdFromDeepLink(uri);
      if (chatId != null) pendingChatId.value = chatId;
    } finally {
      _handlingLink = false;
      final queued = _queuedLink;
      _queuedLink = null;
      if (queued != null) unawaited(handle(queued));
    }
  }

  try {
    // A slow initial link must not hang the splash (M3).
    final initial =
        await links.getInitialLink().timeout(const Duration(seconds: 15));
    await handle(initial);
  } catch (_) {
    // A failed initial-link read must not block the app.
  }
  _linkSubscription = links.uriLinkStream.listen(handle, onError: (_) {});
}

/// Cancels the live deep-link subscription (kept for tests / lifecycle
/// use; the app itself listens for the whole session).
Future<void> disposeDeepLinks() async {
  await _linkSubscription?.cancel();
  _linkSubscription = null;
  _listening = false;
}

/// Arabic message for a failed auth-callback exchange. Each cause gets
/// its own wording so the user knows whether to ask for a new link or
/// just check the connection (M6, B2):
///  - missing PKCE verifier / invalid_grant: the link is dead on this
///    device — ask for a new one;
///  - network failure / timeout: do NOT resend, just retry the link;
///  - expired: ask for a new link.
String deepLinkErrorMessage(Object e) {
  if (e is TimeoutException) {
    return 'تعذّر إكمال التأكيد — انتهت مهلة الاتصال. تحقق من اتصالك وحاول فتح الرابط مجدداً. لا حاجة لطلب رابط جديد.';
  }
  if (e is io.SocketException) {
    return 'تعذّر الوصول إلى الإنترنت أثناء فتح الرابط — تحقق من الاتصال وحاول مجدداً. لا حاجة لطلب رابط جديد.';
  }
  final text = e is AuthException ? e.message : e.toString();
  final lower = text.toLowerCase();
  if (lower.contains('code verifier could not be found')) {
    return 'انتهت صلاحية هذا الرابط على هذا الجهاز — اطلب رابطاً جديداً من زر إعادة الإرسال.';
  }
  if (lower.contains('invalid_grant') ||
      lower.contains('already been used') ||
      lower.contains('flow state not found') ||
      lower.contains('code challenge')) {
    return 'هذا الرابط مستخدم أو منتهي الصلاحية — اطلب رابطاً جديداً من زر إعادة الإرسال.';
  }
  if (lower.contains('socketexception') ||
      lower.contains('clientexception') ||
      lower.contains('failed host lookup')) {
    return 'تعذّر الوصول إلى الإنترنت أثناء فتح الرابط — تحقق من الاتصال وحاول مجدداً. لا حاجة لطلب رابط جديد.';
  }
  if (lower.contains('expired')) {
    return 'انتهت صلاحية رابط التأكيد. اطلب رابطاً جديداً من زر إعادة الإرسال.';
  }
  return 'تعذّر إكمال التأكيد من الرابط. جرّب إعادة إرسال رسالة التأكيد.';
}
