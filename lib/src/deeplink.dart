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

/// The latest error from handling an auth-callback link, if any.
/// The confirmation screen listens to this so a failed link (e.g. an
/// expired one) is explained instead of silently doing nothing.
final ValueNotifier<String?> deepLinkError = ValueNotifier(null);

bool _listening = false;

/// Listen for the app's auth-callback links (cold start + while running)
/// and exchange them for a session. Idempotent: safe to call on every
/// app start/retry. Once the session is stored, the auth-state stream
/// moves the user into the app, so the caller needs no navigation here.
Future<void> setupDeepLinks() async {
  if (_listening) return;
  _listening = true;
  final links = AppLinks();

  Future<void> handle(Uri? uri) async {
    if (uri == null || !isAuthCallback(uri)) return;
    try {
      await Supabase.instance.client.auth.getSessionFromUrl(uri);
    } catch (e) {
      deepLinkError.value = _deepLinkErrorMessage(e);
    }
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
