import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'admin.dart';
import 'calls.dart';
import 'channels.dart';
import 'chat.dart';
import 'deeplink.dart';
import 'diagnostics.dart';
import 'inbox.dart';
import 'push.dart';
import 'utils.dart';

/// Arabic message for a real auth/network failure, or null when [e] is
/// not a recognised failure (callers then fall back to the raw message
/// as a technical detail). This is the auth.dart-local extension of
/// [networkErrorMessage] (M8, B16): it adds the cases the shared helper
/// does not cover yet — TimeoutException, TLS handshake failures,
/// HTTP 429, and the common GoTrue messages — and it names the caller's
/// [operation] instead of hardcoding "إنشاء الحساب" in the decode-error
/// text. NOTE for the coordinator: these cases belong in utils.dart's
/// networkErrorMessage centrally (with an `operation` parameter); this
/// local mapper exists only because utils.dart is owned centrally and
/// must not be edited by two agents at once.
String? authErrorMessage(Object e, {String operation = 'إتمام العملية'}) {
  final network = networkErrorMessage(e);
  if (network != null) {
    // networkErrorMessage hardcodes 'إنشاء الحساب' in its decode-error
    // text; rewrite it with the caller's operation.
    if (network.contains('إنشاء الحساب') && operation != 'إنشاء الحساب') {
      return network.replaceFirst('إنشاء الحساب', operation);
    }
    return network;
  }
  if (e is TimeoutException) {
    return 'انتهت مهلة الاتصال بالخادم أثناء $operation. تحقق من اتصالك وحاول مجدداً.';
  }
  if (e is io.HandshakeException || e is io.TlsException) {
    return 'تعذّر إنشاء اتصال آمن بالخادم أثناء $operation. جرّب شبكة أخرى.';
  }
  final text = e is AuthException ? e.message : e.toString();
  final lower = text.toLowerCase();
  if (lower.contains('429') ||
      lower.contains('too many requests') ||
      lower.contains('rate limit') ||
      lower.contains('rate_limit')) {
    return 'طلبات كثيرة جداً — انتظر دقيقة ثم أعد المحاولة.';
  }
  if (lower.contains('email not confirmed')) {
    return 'أكد بريدك الإلكتروني أولاً من الرسالة التي وصلتك.';
  }
  if (lower.contains('invalid login credentials')) {
    return 'البريد أو كلمة المرور غير صحيحة.';
  }
  if (lower.contains('user already registered')) {
    return 'هذا البريد مسجل بالفعل — سجّل الدخول بدلاً من إنشاء حساب.';
  }
  if (lower.contains('failed to decode error response') ||
      lower.contains('received an empty response')) {
    return 'وصل رد غير متوقع من الخادم أثناء $operation. جرّب شبكة أخرى أو أعد المحاولة.';
  }
  return null;
}

/// Awaited sign-out with a busy indicator and an Arabic error snackbar
/// on failure (B14). Every sign-out in auth.dart goes through here
/// instead of fire-and-forget `auth.signOut()`.
Future<void> signOutSafely(BuildContext context) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogShown = false;
  try {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    dialogShown = true;
  } catch (_) {
    // No busy indicator, but the sign-out itself must still run.
  }
  try {
    // Best-effort: prune this device's push token so a signed-out phone
    // stops receiving this user's notifications. Never blocks sign-out.
    await deletePushTokenOnSignOut();
  } catch (_) {
    // Token pruning is best-effort; sign-out proceeds regardless.
  }
  try {
    await Supabase.instance.client.auth
        .signOut()
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    final message = authErrorMessage(e, operation: 'تسجيل الخروج') ??
        'تعذّر تسجيل الخروج. تحقق من الاتصال وحاول مجدداً.';
    final messengerContext = helbaNavigatorKey.currentContext;
    if (messengerContext != null) {
      // This context is fetched fresh from the navigator key after the
      // await, not the BuildContext passed into this function.
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(messengerContext)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  } finally {
    if (dialogShown) {
      try {
        navigator.pop();
      } catch (_) {}
    }
  }
}

/// Validate the configuration and initialize Supabase. Returns an Arabic
/// error message, or null when the app is ready to run. Kept separate from
/// main() so a failed start can be retried from the setup screen instead
/// of leaving the user on a dead end.
Future<String?> initializeHelba() async {
  const configuredUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: supabaseUrlDefault);
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY',
      defaultValue: supabasePublishableKeyDefault);
  // Remove accidental spaces/newlines from build-time configuration before parsing the host.
  final url = configuredUrl
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'/+$'), '');
  final parsedUrl = Uri.tryParse(url);
  if (parsedUrl == null ||
      parsedUrl.scheme != 'https' ||
      parsedUrl.host.isEmpty) {
    return 'رابط Supabase غير صحيح. المتوقع https://<project-ref>.supabase.co';
  }
  if (key.isEmpty) {
    return 'مفتاح Supabase مفقود. أضف SUPABASE_PUBLISHABLE_KEY.';
  }
  if (Supabase.instance.isInitialized) return null;
  try {
    await Supabase.initialize(url: url, publishableKey: key)
        .timeout(const Duration(seconds: 15));
    return null;
  } on TimeoutException catch (_) {
    return 'تعذر الاتصال بـ Supabase (انتهت مهلة الاتصال). تحقق من اتصالك وحاول مجدداً.';
  } catch (e) {
    // M7: keep the friendly user-facing text, but append the underlying
    // cause (class + message) in a developer-readable form instead of
    // swallowing it.
    final friendly = networkErrorMessage(e) ??
        'تعذر الاتصال بـ Supabase. تحقق من الرابط والمفتاح والاتصال.';
    final cause = e is AuthException ? e.message : e.toString();
    return '$friendly (تفاصيل تقنية: ${e.runtimeType}: $cause)';
  }
}

class HelbaApp extends StatefulWidget {
  const HelbaApp({super.key});
  @override
  State<HelbaApp> createState() => _HelbaAppState();
}

class _HelbaAppState extends State<HelbaApp> {
  bool _starting = true;
  String? _configError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _configError = null;
    });
    String? error;
    try {
      error = await initializeHelba();
      if (error == null) {
        // Supabase is ready: start listening for the email-confirmation
        // link that returns the user to the app. Deep-link setup must
        // never hang the splash (M3): bounded by its own timeout plus
        // this one, and _starting is always cleared in the finally.
        try {
          await setupDeepLinks().timeout(const Duration(seconds: 20));
        } catch (_) {
          // A failed deep-link setup must not block startup.
        }
      }
    } catch (_) {
      error ??= 'تعذر بدء التطبيق. أعد المحاولة.';
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
          _configError = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'هلبة',
        debugShowCheckedModeBanner: false,
        // The calls service shows the incoming-call overlay through this
        // key, so a call rings from anywhere in the app (inbox or chat).
        navigatorKey: helbaNavigatorKey,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: green),
          scaffoldBackgroundColor: const Color(0xFFF5F8F6),
          fontFamily: 'Arial',
        ),
        home: Directionality(
          textDirection: ui.TextDirection.rtl,
          child: _starting
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _configError != null
                  ? SetupPage(message: _configError, onRetry: _start)
                  : const AuthGate(),
        ),
      );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? boundEmail;
  bool loading = true;
  bool _binding = false;
  bool _bindFailed = false;
  // The signed-in user's profile (admin / banned flags). Loaded once per
  // user id, following the _bind / addPostFrameCallback pattern so the
  // fetch never runs inside build() and never loops on rebuilds.
  Map<String, dynamic>? _myProfile;
  String? _profileUserId;
  bool _loadingProfile = false;
  bool _clearingProfile = false;
  // Profile-load failure state (B3/B4): set only after the retry budget
  // is exhausted; [_profileFailedDismissed] is the user's explicit
  // choice to continue to the inbox without a profile.
  bool _profileFailed = false;
  bool _profileFailedDismissed = false;
  int _profileAttempts = 0;
  // Guards the pending-chat navigation so one link / notification tap
  // opens exactly one ChatPage even if build() runs repeatedly.
  bool _openingChat = false;
  // Set when a password-recovery link is exchanged (B1): the user must
  // set a new password before entering the app, even if already signed
  // in or still unconfirmed.
  bool _passwordRecovery = false;
  // M1: whether the auth stream has errored and a refresh was attempted.
  bool _authRefreshAttempted = false;
  // M2: the user id the call/push services were last started for, so
  // startListening()/setupPushNotifications() run once per user, never
  // on every rebuild.
  String? _lastServicesUserId;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Listen for auth events directly: PASSWORD_RECOVERY is how a reset
    // link announces itself, and SIGNED_OUT resets the per-user guards
    // (including _binding, B13).
    _authSub = Supabase.instance.client.auth.onAuthStateChange
        .listen(_onAuthStateChange);
    // A chat deep link or a notification tap sets pendingChatId; when it
    // fires while the user is already signed in, open the chat now. A
    // link that arrived before sign-in is picked up from build() below.
    pendingChatId.addListener(_onPendingChat);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    pendingChatId.removeListener(_onPendingChat);
    super.dispose();
  }

  void _onAuthStateChange(AuthState state) {
    if (!mounted) return;
    if (state.event == AuthChangeEvent.passwordRecovery) {
      setState(() => _passwordRecovery = true);
    } else if (state.event == AuthChangeEvent.signedOut) {
      setState(() {
        _passwordRecovery = false;
        _binding = false;
        _bindFailed = false;
        _lastServicesUserId = null;
        _myProfile = null;
        _profileUserId = null;
        _loadingProfile = false;
        _profileFailed = false;
        _profileFailedDismissed = false;
        _profileAttempts = 0;
      });
    }
  }

  Future<void> _tryRefreshAuth() async {
    try {
      await Supabase.instance.client.auth
          .refreshSession()
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // The error screen stays visible; its retry button re-runs this.
    }
  }

  void _onPendingChat() {
    if (pendingChatId.value == null) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || user.emailConfirmedAt == null) return;
    unawaited(_openPendingChat());
  }

  void _showPendingChatError(String message) {
    final context = helbaNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the chat queued in [pendingChatId] (deep link `helba://chat/<id>`
  /// or a tapped push notification). The id is cleared only after the
  /// push succeeds (B8): if the user signs out mid-flight the id is kept
  /// so the link is not lost, and a failed lookup shows a snackbar and
  /// consumes the id instead of navigating to a wrong chat (B9).
  Future<void> _openPendingChat() async {
    final conversationId = pendingChatId.value;
    if (conversationId == null || _openingChat) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || user.emailConfirmedAt == null) return;
    if (!isValidUuid(conversationId)) {
      pendingChatId.value = null;
      _showPendingChatError('رابط المحادثة غير صالح.');
      return;
    }
    _openingChat = true;
    try {
      final resolved = await _resolveChat(conversationId, user.id);
      // Re-check auth after the await: a sign-out mid-flight must not
      // consume the link (B8) — keep the id for the next sign-in.
      final current = Supabase.instance.client.auth.currentUser;
      if (current == null || current.emailConfirmedAt == null) return;
      if (resolved == null) {
        pendingChatId.value = null;
        _showPendingChatError(
            'تعذّر فتح المحادثة — تحقق من الاتصال أو عضويتك.');
        return;
      }
      final navigator = helbaNavigatorKey.currentState;
      if (navigator == null) return; // Keep the id; retry on next build.
      navigator.push(MaterialPageRoute(
          builder: (_) => ChatPage(
              conversationId: conversationId,
              title: resolved.title,
              kind: resolved.kind,
              isAdmin: resolved.isAdmin)));
      pendingChatId.value = null;
    } finally {
      _openingChat = false;
    }
  }

  /// Resolves a deep-linked chat, or null when it must not be opened:
  /// lookup failure, an invalid id, or the user not being a member (B9,
  /// B-2). No fallback title/kind/admin is invented here any more.
  Future<({String title, String kind, bool isAdmin})?> _resolveChat(
      String conversationId, String myId) async {
    if (!isValidUuid(conversationId)) return null;
    try {
      final rows = await Supabase.instance.client
          .from('conversation_members')
          .select(
              'user_id,role,profiles(display_name,username),conversations(id,title,kind)')
          .eq('conversation_id', conversationId)
          .timeout(const Duration(seconds: 15));
      final members = (rows as List).cast<Map<String, dynamic>>();
      if (members.isEmpty) return null;
      // Never open a chat the user is not a member of.
      if (!members.any((m) => m['user_id']?.toString() == myId)) return null;
      final conversation =
          members.first['conversations'] as Map<String, dynamic>?;
      final kind = conversation?['kind']?.toString() ?? 'direct';
      var title = conversation?['title']?.toString().trim() ?? '';
      if (title.isEmpty && kind == 'direct') {
        for (final member in members) {
          if (member['user_id']?.toString() == myId) continue;
          final profile = member['profiles'] as Map<String, dynamic>?;
          final name =
              profile?['display_name']?.toString().trim().isNotEmpty == true
                  ? profile!['display_name'].toString()
                  : (profile?['username']?.toString().isNotEmpty == true
                      ? '@${profile!['username']}'
                      : '');
          if (name.isNotEmpty) {
            title = name;
            break;
          }
        }
      }
      if (title.isEmpty) title = 'محادثة';
      final isAdmin = roleInConversation(
              {
                'conversation_members': members
                    .map((m) => {'user_id': m['user_id'], 'role': m['role']})
                    .toList()
              },
              myId) ==
          'admin';
      return (title: title, kind: kind, isAdmin: isAdmin);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    try {
      // M13: a hung keystore must not hang the splash.
      boundEmail = await secureStore
          .read(key: 'helba_bound_email')
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      boundEmail = null;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _bind(String email) async {
    final normalized = normalizeEmail(email);
    try {
      await secureStore
          .write(key: 'helba_bound_email', value: normalized)
          .timeout(const Duration(seconds: 5));
      if (mounted) setState(() => boundEmail = normalized);
    } catch (_) {
      // A failed bind must not block sign-in; the next launch retries it.
      // _bindFailed stops the build trigger below from retrying on every
      // rebuild (the bind is retried on the next launch / sign-in).
      if (mounted) setState(() => _bindFailed = true);
    } finally {
      // B13: always release the flag so a second user on the same
      // install can be device-bound (it is reset on sign-out too).
      if (mounted) setState(() => _binding = false);
    }
  }

  /// Loads the signed-in user's profile. [_profileUserId] is set only
  /// after a successful load (B3): on failure it stays null so the
  /// build trigger can retry, with back-off — up to 3 attempts
  /// (delays 2s, then 4s). A missing row is a success (not-admin /
  /// not-banned), not a failure.
  Future<void> _loadMyProfile(String uid) async {
    try {
      final profile = await loadMyProfile().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser?.id != uid) return;
      setState(() {
        _myProfile = profile;
        _profileUserId = uid;
        _loadingProfile = false;
        _profileFailed = false;
        _profileFailedDismissed = false;
        _profileAttempts = 0;
      });
    } catch (_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser?.id != uid) return;
      _profileAttempts += 1;
      if (_profileAttempts < 3) {
        await Future.delayed(Duration(seconds: _profileAttempts * 2));
        if (!mounted) return;
        if (Supabase.instance.client.auth.currentUser?.id != uid) return;
        return _loadMyProfile(uid);
      }
      setState(() {
        _loadingProfile = false;
        _profileFailed = true;
      });
    }
  }

  void _retryProfile() {
    setState(() {
      _profileFailed = false;
      _profileFailedDismissed = false;
      _profileAttempts = 0;
      _loadingProfile = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // M1: wait for the first auth event instead of flashing the
        // login screen on cold start, and surface stream errors instead
        // of leaving a stale user on screen.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError) {
          if (!_authRefreshAttempted) {
            _authRefreshAttempted = true;
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => unawaited(_tryRefreshAuth()));
          }
          return Scaffold(
              body: Center(
                  child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('تعذّر التحقق من الجلسة',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('تحقق من اتصالك بالإنترنت ثم أعد المحاولة.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () {
                    setState(() => _authRefreshAttempted = false);
                    unawaited(_tryRefreshAuth());
                  },
                  child: const Text('إعادة المحاولة')),
            ]),
          )));
        }
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) {
          _binding = false;
          _bindFailed = false;
          _lastServicesUserId = null;
          if (_profileUserId != null && !_clearingProfile) {
            _clearingProfile = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _myProfile = null;
                  _profileUserId = null;
                  _loadingProfile = false;
                  _clearingProfile = false;
                });
              }
            });
          }
          // Signed out: stop listening for incoming calls.
          unawaited(CallService.instance.stopListening());
          return LoginPage(boundEmail: boundEmail, onSignedIn: _bind);
        }
        final email = normalizeEmail(user.email ?? '');
        if (boundEmail != null && boundEmail != email) {
          return Scaffold(
              body: Center(
                  child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48, color: green),
              const SizedBox(height: 12),
              const Text('هذا التثبيت مرتبط ببريد آخر',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              // B14: show WHICH email this install is bound to, and the
              // way out (sign in with it, or ask an admin to unbind).
              Text(
                  'مرتبط بـ ${boundEmail ?? ''} — سجّل الدخول به أو تواصل مع الإدارة لإلغاء الربط.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () => unawaited(signOutSafely(context)),
                  child: const Text('تسجيل الخروج')),
            ]),
          )));
        }
        // B1: a password-recovery session goes to the set-new-password
        // screen first — even for an already signed-in user, and even
        // when the account is still unconfirmed (the recovery session
        // would otherwise be wasted on the unconfirmed screen).
        if (_passwordRecovery) {
          return SetNewPasswordPage(
              onDone: () {
                if (mounted) setState(() => _passwordRecovery = false);
              });
        }
        // Sign-up used to land straight in the inbox without confirming the
        // email, because only the sign-in path checked emailConfirmedAt.
        // Enforce confirmation here for every session, whatever created it.
        if (user.emailConfirmedAt == null) {
          return UnconfirmedEmailPage(email: email);
        }
        if (boundEmail == null && !_binding && !_bindFailed) {
          _binding = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => unawaited(_bind(email)));
        }
        // Load the profile (admin / banned flags) when a different user
        // is seen; a missing row means not-admin / not-banned. The user
        // id is recorded only after a successful load (B3).
        if (_profileUserId != user.id &&
            !_loadingProfile &&
            !_profileFailed) {
          _loadingProfile = true;
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => unawaited(_loadMyProfile(user.id)));
        }
        // B4: never show the inbox (and never start call/push listening)
        // while the profile is unresolved — a banned user used to see the
        // inbox on the first frames because _myProfile was still null.
        final profileResolved = _profileUserId == user.id;
        if (!profileResolved && !_profileFailedDismissed) {
          if (_profileFailed) {
            return Scaffold(
                body: Center(
                    child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off_outlined,
                    size: 48, color: Colors.orange),
                const SizedBox(height: 12),
                const Text('تعذّر تحميل ملف حسابك',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('تحقق من اتصالك بالإنترنت ثم أعد المحاولة.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _retryProfile,
                    child: const Text('إعادة المحاولة')),
                const SizedBox(height: 8),
                TextButton(
                    onPressed: () =>
                        setState(() => _profileFailedDismissed = true),
                    child:
                        const Text('المتابعة إلى الرسائل بدون ملف الحساب')),
              ]),
            )));
          }
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (isBannedProfile(_myProfile)) {
          return const BannedAccountPage();
        }
        // M2: start the call/push services once per user, not on every
        // rebuild. (Both services are idempotent, but the guard keeps
        // the side effect out of build().)
        if (_lastServicesUserId != user.id) {
          _lastServicesUserId = user.id;
          unawaited(CallService.instance.startListening());
          // Register the FCM token and listen for messages. Inert until
          // Firebase is configured (see push.dart).
          unawaited(setupPushNotifications());
          // Retry a previously failed token upsert (e.g. a network blip
          // at the last sign-in) now that we are signed in again.
          unawaited(retryPushTokenUpsert());
        }
        // A chat link / notification tap may have arrived before sign-in
        // (or before this listener existed): pick it up now.
        if (pendingChatId.value != null) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => unawaited(_openPendingChat()));
        }
        return InboxPage(isAdmin: isAdminProfile(_myProfile));
      },
    );
  }
}

/// Shown instead of the inbox when the signed-in account is banned.
class BannedAccountPage extends StatelessWidget {
  const BannedAccountPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
          body: Center(
              child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.block_outlined, size: 48, color: Colors.red),
          const SizedBox(height: 12),
          const Text('تم حظر هذا الحساب',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text(
              'تم حظر حسابك من قبل الإدارة. تواصل مع الإدارة إذا كنت تعتقد أن هذا خطأ.',
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => unawaited(signOutSafely(context)),
              child: const Text('تسجيل الخروج')),
        ]),
      )));
}

/// Set a new password after following a password-reset link (B1).
/// Shown by AuthGate when a PASSWORD_RECOVERY event arrives; only after
/// a successful update does the app route to the inbox.
class SetNewPasswordPage extends StatefulWidget {
  final VoidCallback onDone;
  const SetNewPasswordPage({super.key, required this.onDone});
  @override
  State<SetNewPasswordPage> createState() => _SetNewPasswordPageState();
}

class _SetNewPasswordPageState extends State<SetNewPasswordPage> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.length < 8) {
      setState(() => _error = 'كلمة المرور من 8 أحرف على الأقل.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth
          .updateUser(UserAttributes(password: _password.text))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تغيير كلمة المرور بنجاح.')));
      widget.onDone();
    } on AuthException catch (ex) {
      if (mounted) {
        setState(() => _error = authErrorMessage(ex,
                operation: 'تغيير كلمة المرور') ??
            ex.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = authErrorMessage(e,
                operation: 'تغيير كلمة المرور') ??
            'تعذّر تغيير كلمة المرور. حاول مجدداً.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: SafeArea(
              child: Center(
                  child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_reset_outlined,
                      size: 48, color: green),
                  const SizedBox(height: 12),
                  const Text('تعيين كلمة مرور جديدة',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                      'وصلت عبر رابط استعادة كلمة المرور. أدخل كلمة مرور جديدة لحسابك.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  TextField(
                      controller: _password,
                      obscureText: _hidePassword,
                      decoration: InputDecoration(
                          labelText: 'كلمة المرور الجديدة',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                              icon: Icon(_hidePassword
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              onPressed: () => setState(
                                  () => _hidePassword = !_hidePassword)),
                          border: const OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                      controller: _confirm,
                      obscureText: _hidePassword,
                      decoration: const InputDecoration(
                          labelText: 'تأكيد كلمة المرور الجديدة',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder())),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.red))),
                  const SizedBox(height: 18),
                  FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const CircularProgressIndicator()
                          : const Text('حفظ كلمة المرور الجديدة')),
                  TextButton(
                      onPressed:
                          _busy ? null : () => unawaited(signOutSafely(context)),
                      child: const Text('تسجيل الخروج')),
                ])),
      ))));
}

class UnconfirmedEmailPage extends StatefulWidget {
  final String email;
  final VoidCallback? onBackToLogin;
  const UnconfirmedEmailPage(
      {super.key, required this.email, this.onBackToLogin});
  @override
  State<UnconfirmedEmailPage> createState() => _UnconfirmedEmailPageState();
}

class _UnconfirmedEmailPageState extends State<UnconfirmedEmailPage> {
  bool busy = false;
  bool checking = false;
  String? message;
  String? error;
  // M9: resend cooldown — 60s after a successful resend, with a
  // countdown label, so the button cannot be hammered (and a 429 from
  // the server is surfaced instead of silently re-sending).
  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    deepLinkError.addListener(_onDeepLinkError);
    // A link may already have failed before this screen appeared.
    // Consume-and-clear (B10): the error belongs to this screen now.
    if (deepLinkError.value != null) {
      error = deepLinkError.value;
      deepLinkError.value = null;
    }
  }

  void _onDeepLinkError() {
    if (mounted && deepLinkError.value != null) {
      setState(() => error = deepLinkError.value);
      deepLinkError.value = null;
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    deepLinkError.removeListener(_onDeepLinkError);
    super.dispose();
  }

  void _startResendCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldown <= 1) {
        timer.cancel();
        setState(() => _resendCooldown = 0);
      } else {
        setState(() => _resendCooldown -= 1);
      }
    });
  }

  Future<void> _resend() async {
    deepLinkError.value = null;
    setState(() {
      busy = true;
      message = null;
      error = null;
    });
    try {
      await Supabase.instance.client.auth
          .resend(
              email: widget.email,
              type: OtpType.signup,
              emailRedirectTo: authCallbackUrl)
          .timeout(const Duration(seconds: 15));
      if (mounted) {
        setState(() =>
            message = 'أرسلنا رابط تأكيد جديد إلى بريدك الإلكتروني.');
        _startResendCooldown();
      }
    } on AuthException catch (ex) {
      if (mounted) {
        setState(() => error = authErrorMessage(ex,
                operation: 'إعادة إرسال رابط التأكيد') ??
            ex.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = authErrorMessage(e, operation: 'إعادة إرسال رابط التأكيد') ??
                'تعذر إرسال رابط التأكيد. حاول مجدداً.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// M10: "already confirmed? check again" — refresh the session and
  /// re-read the user; if the email is now confirmed, the auth stream
  /// routes into the app on its own.
  Future<void> _checkConfirmation() async {
    setState(() {
      checking = true;
      message = null;
      error = null;
    });
    try {
      await Supabase.instance.client.auth
          .refreshSession()
          .timeout(const Duration(seconds: 15));
      final response = await Supabase.instance.client.auth
          .getUser()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (response.user?.emailConfirmedAt != null) {
        setState(() => message = 'تم التأكيد — جارٍ الدخول…');
      } else {
        setState(() =>
            message = 'لم يتم التأكيد بعد — افتح رابط التأكيد في بريدك.');
      }
    } on AuthException catch (ex) {
      if (mounted) {
        setState(() => error =
            authErrorMessage(ex, operation: 'التحقق من التأكيد') ??
                ex.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = authErrorMessage(e, operation: 'التحقق من التأكيد') ??
                'تعذر التحقق الآن. حاول مجدداً.');
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  /// B2: signing out here destroys the PKCE code-verifier, so the
  /// confirmation link already sent to the user's inbox stops working.
  /// Keep the button, but only behind a warning dialog that says so.
  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تسجيل الخروج؟'),
        content: const Text(
            'تسجيل الخروج يُبطل رابط التأكيد المُرسل إلى بريدك — ستحتاج إلى طلب رابط جديد.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('البقاء')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('تسجيل الخروج')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await signOutSafely(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: Center(
              child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.mark_email_unread_outlined, size: 48, color: green),
          const SizedBox(height: 12),
          const Text('أكد بريدك الإلكتروني أولاً',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('أرسلنا رابط تأكيد إلى ${widget.email}. افتحه وستعود إلى التطبيق مباشرة.',
              textAlign: TextAlign.center),
          if (message != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                    Text(message!, style: const TextStyle(color: green))),
          if (error != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!,
                    style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 16),
          FilledButton(
              onPressed:
                  (busy || checking || _resendCooldown > 0) ? null : _resend,
              child: Text(_resendCooldown > 0
                  ? 'إعادة الإرسال بعد $_resendCooldown ث'
                  : 'إعادة إرسال رابط التأكيد')),
          const SizedBox(height: 8),
          OutlinedButton(
              onPressed: (busy || checking) ? null : _checkConfirmation,
              child: checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('أكّدت؟ تحقق الآن')),
          const SizedBox(height: 8),
          TextButton(
              onPressed:
                  (busy || checking) ? null : () => unawaited(_confirmSignOut()),
              child: const Text('تسجيل الخروج')),
          if (widget.onBackToLogin != null)
            TextButton(
                onPressed: widget.onBackToLogin,
                child: const Text('العودة لتسجيل الدخول')),
        ]),
      )));
}

class SetupPage extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;
  const SetupPage({super.key, this.message, this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(
          body: Center(
              child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.settings_outlined, size: 48, color: green),
          const SizedBox(height: 12),
          Text(
              message ??
                  'أضف SUPABASE_URL وSUPABASE_PUBLISHABLE_KEY لتفعيل هلبة.',
              textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
          ],
          // M7: the diagnostics screen needs no signed-in session, so
          // it is reachable from the setup screen too.
          const SizedBox(height: 8),
          TextButton(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const NetworkDiagnosticsPage())),
              child: const Text('تشخيص الشبكة')),
        ]),
      )));
}

class LoginPage extends StatefulWidget {
  final String? boundEmail;
  final Future<void> Function(String) onSignedIn;
  const LoginPage({super.key, required this.boundEmail, required this.onSignedIn});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool signup = false, busy = false, hidePassword = true;
  String? error, message, errorDetail;
  // M11: after a session-less sign-up, the login form is replaced by
  // the unconfirmed-email screen instead of leaving the user on the
  // form with only a green line.
  String? _pendingConfirmationEmail;

  @override
  void initState() {
    super.initState();
    if (widget.boundEmail != null) email.text = widget.boundEmail!;
    // B10: surface deep-link errors on the login screen too, and
    // consume-and-clear them so they do not linger on later screens.
    deepLinkError.addListener(_onDeepLinkError);
    if (deepLinkError.value != null) {
      error = deepLinkError.value;
      deepLinkError.value = null;
    }
  }

  void _onDeepLinkError() {
    if (mounted && deepLinkError.value != null) {
      setState(() => error = deepLinkError.value);
      deepLinkError.value = null;
    }
  }

  @override
  void dispose() {
    deepLinkError.removeListener(_onDeepLinkError);
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final e = normalizeEmail(email.text);
    if (!e.contains('@') || password.text.length < 8) {
      setState(() {
        error = 'أدخل بريداً صحيحاً وكلمة مرور من 8 أحرف على الأقل.';
        errorDetail = null;
      });
      return;
    }
    if (widget.boundEmail != null && widget.boundEmail != e) {
      setState(() {
        error =
            'هذا الجهاز مرتبط بالبريد ${widget.boundEmail} ولا يقبل بريداً آخر.';
        errorDetail = null;
      });
      return;
    }
    final operation = signup ? 'إنشاء الحساب' : 'تسجيل الدخول';
    setState(() {
      busy = true;
      error = null;
      message = null;
      errorDetail = null;
    });
    try {
      final auth = Supabase.instance.client.auth;
      if (signup) {
        final result = await auth
            .signUp(
                email: e,
                password: password.text,
                emailRedirectTo: authCallbackUrl)
            .timeout(const Duration(seconds: 15));
        if (!mounted) return;
        if (result.session != null) {
          // B11: a session means the account is already confirmed
          // (auto-confirm) — no confirmation email was sent, so do not
          // claim one was, and do NOT sign out (B2). Switch to login
          // mode; AuthGate routes the confirmed session into the app.
          setState(() {
            signup = false;
            message = 'تم إنشاء الحساب — سجّل الدخول الآن';
          });
        } else {
          // M11: route to the unconfirmed screen for this email.
          setState(() => _pendingConfirmationEmail = e);
        }
      } else {
        final result = await auth
            .signInWithPassword(email: e, password: password.text)
            .timeout(const Duration(seconds: 15));
        if (!mounted) return;
        if (result.user?.emailConfirmedAt == null) {
          // B2: do NOT sign out — signing out deletes the PKCE
          // code-verifier and destroys the confirmation link. Stay
          // signed in; AuthGate routes to UnconfirmedEmailPage.
          setState(() =>
              error = 'أكد بريدك الإلكتروني أولاً من الرسالة التي وصلتك.');
        } else {
          await widget.onSignedIn(e);
        }
      }
    } on AuthException catch (ex) {
      if (!mounted) return;
      final friendly = authErrorMessage(ex, operation: operation);
      setState(() {
        error = friendly ?? ex.message;
        errorDetail = friendly == null ? null : ex.message;
      });
    } catch (e) {
      if (!mounted) return;
      final friendly = authErrorMessage(e, operation: operation);
      setState(() {
        error = friendly ?? 'تعذر الاتصال بالخدمة. حاول مجدداً.';
        errorDetail = friendly == null ? null : e.toString();
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingConfirmationEmail != null) {
      return UnconfirmedEmailPage(
          email: _pendingConfirmationEmail!,
          onBackToLogin: () =>
              setState(() => _pendingConfirmationEmail = null));
    }
    return Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.forum_rounded, color: green, size: 68),
                const SizedBox(height: 12),
                const Text('هلبة',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 36, fontWeight: FontWeight.w900)),
                const Text('تواصل يجمعنا', textAlign: TextAlign.center),
                Text(
                    'الإصدار ${buildCommit.length >= 7 ? buildCommit.substring(0, 7) : buildCommit}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black45)),
                const SizedBox(height: 36),
                Text(signup ? 'إنشاء حساب جديد' : 'تسجيل الدخول',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'البريد الإلكتروني',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(
                    controller: password,
                    obscureText: hidePassword,
                    decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                            icon: Icon(hidePassword
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () => setState(
                                () => hidePassword = !hidePassword)),
                        border: const OutlineInputBorder())),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!,
                          style: const TextStyle(color: Colors.red))),
                if (errorDetail != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(errorDetail!,
                          style: const TextStyle(
                              color: Colors.black54, fontSize: 12))),
                if (message != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(message!,
                          style: const TextStyle(color: green))),
                const SizedBox(height: 18),
                FilledButton(
                    onPressed: busy ? null : submit,
                    child: busy
                        ? const CircularProgressIndicator()
                        : Text(signup ? 'إنشاء الحساب' : 'دخول')),
                TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              signup = !signup;
                              error = null;
                              message = null;
                              errorDetail = null;
                            }),
                    child: Text(signup
                        ? 'لديك حساب؟ سجل الدخول'
                        : 'ليس لديك حساب؟ أنشئ حساباً')),
                TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final e = normalizeEmail(email.text);
                            if (!e.contains('@')) {
                              setState(() =>
                                  error = 'أدخل بريدك الإلكتروني أولاً.');
                              return;
                            }
                            // M12: a reset email for a different address
                            // would sign that account in and land on the
                            // device-mismatch screen — reject it here.
                            if (widget.boundEmail != null &&
                                widget.boundEmail != e) {
                              setState(() => error =
                                  'هذا الجهاز مرتبط بالبريد ${widget.boundEmail} — لا يمكن إرسال رسالة استعادة إلى بريد آخر.');
                              return;
                            }
                            setState(() {
                              busy = true;
                              error = null;
                              message = null;
                              errorDetail = null;
                            });
                            try {
                              await Supabase.instance.client.auth
                                  .resetPasswordForEmail(e,
                                      redirectTo: authCallbackUrl)
                                  .timeout(const Duration(seconds: 15));
                              if (mounted) {
                                setState(() => message =
                                    'إذا كان البريد مسجلاً فستصلك رسالة استعادة كلمة المرور.');
                              }
                            } on AuthException catch (ex) {
                              final friendly = authErrorMessage(ex,
                                  operation: 'استعادة كلمة المرور');
                              if (mounted) {
                                setState(() {
                                  error = friendly ?? ex.message;
                                  errorDetail =
                                      friendly == null ? null : ex.message;
                                });
                              }
                            } catch (e) {
                              final friendly = authErrorMessage(e,
                                  operation: 'استعادة كلمة المرور');
                              if (mounted) {
                                setState(() {
                                  error = friendly ??
                                      'تعذر إرسال رسالة الاستعادة. تحقق من الاتصال وحاول مجدداً.';
                                  errorDetail =
                                      friendly == null ? null : e.toString();
                                });
                              }
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    child: const Text('نسيت كلمة المرور؟')),
                TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const NetworkDiagnosticsPage())),
                    child: const Text('تشخيص الشبكة')),
              ],
            )),
      ))),
    );
  }
}
