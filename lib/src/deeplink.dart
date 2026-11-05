import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The URL Supabase redirects the email-confirmation (and password-reset)
/// link to, and the app opens for. Three places must agree on it:
///  - the Android manifest carries an intent-filter for this scheme
///    (patched in by the build workflow, since android/ is generated);
///  - the Supabase dashboard lists it as the Site URL and a Redirect URL;
///  - the app passes it as emailRedirectTo / redirectTo when sending
///    those emails (see auth.dart).
const authCallbackUrl = 'helba://auth/callback';

/// True when [uri] is the app's auth callback (email confirmation,
/// password reset, magic link). The host check keeps unrelated helba://
/// links (if any are ever added) out of the auth flow.
bool isAuthCallback(Uri uri) => uri.scheme == 'helba' && uri.host == 'auth';

/// True when [uri] is a chat deep link: `helba://chat/<conversation_id>`
/// with exactly one non-empty path segment. Anything else (auth links,
/// other schemes/hosts, an empty id, extra segments) is not a chat link.
bool isChatDeepLink(Uri uri) {
  if (uri.scheme != 'helba' || uri.host != 'chat') return false;
  final segments = uri.pathSegments;
  return segments.length == 1 && segments.first.isNotEmpty;
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
    if (isAuthCallback(uri)) {
      try {
        await Supabase.instance.client.auth.getSessionFromUrl(uri);
      } catch (e) {
        deepLinkError.value = _deepLinkErrorMessage(e);
      }
      return;
    }
    final chatId = chatIdFromDeepLink(uri);
    if (chatId != null) pendingChatId.value = chatId;
  }

  try {
    await handle(await links.getInitialLink());
  } catch (_) {
    // A failed initial-link read must not block the app.
  }
  links.uriLinkStream.listen(handle, onError: (_) {});
}

String _deepLinkErrorMessage(Object e) {
  final text = e is AuthException ? e.message : e.toString();
  if (text.toLowerCase().contains('expired')) {
    return 'انتهت صلاحية رابط التأكيد. اطلب رابطاً جديداً من زر إعادة الإرسال.';
  }
  return 'تعذّر إكمال التأكيد من الرابط. جرّب إعادة إرسال رسالة التأكيد.';
}
