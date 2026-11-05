import 'dart:async';
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
    await Supabase.initialize(url: url, publishableKey: key);
    return null;
  } catch (_) {
    return 'تعذر الاتصال بـ Supabase. تحقق من الرابط والمفتاح والاتصال.';
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
    final error = await initializeHelba();
    if (error == null) {
      // Supabase is ready: start listening for the email-confirmation
      // link that returns the user to the app.
      await setupDeepLinks();
    }
    if (mounted) {
      setState(() {
        _starting = false;
        _configError = error;
      });
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
  // The signed-in user's profile (admin / banned flags). Loaded once per
  // user id, following the _bind / addPostFrameCallback pattern so the
  // fetch never runs inside build() and never loops on rebuilds.
  Map<String, dynamic>? _myProfile;
  String? _profileUserId;
  bool _loadingProfile = false;
  bool _clearingProfile = false;
  // Guards the pending-chat navigation so one link / notification tap
  // opens exactly one ChatPage even if build() runs repeatedly.
  bool _openingChat = false;

  @override
  void initState() {
    super.initState();
    _load();
    // A chat deep link or a notification tap sets pendingChatId; when it
    // fires while the user is already signed in, open the chat now. A
    // link that arrived before sign-in is picked up from build() below.
    pendingChatId.addListener(_onPendingChat);
  }

  @override
  void dispose() {
    pendingChatId.removeListener(_onPendingChat);
    super.dispose();
  }

  void _onPendingChat() {
    if (pendingChatId.value == null) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || user.emailConfirmedAt == null) return;
    unawaited(_openPendingChat());
  }

  /// Opens the chat queued in [pendingChatId] (deep link `helba://chat/<id>`
  /// or a tapped push notification) and clears it first, so a rebuild or
  /// a second listener firing can never open it twice. Resolves the title
  /// like the inbox does (conversation title, or the other participant's
  /// display name for direct chats); any lookup failure falls back to
  /// 'محادثة' instead of blocking the navigation.
  Future<void> _openPendingChat() async {
    final conversationId = pendingChatId.value;
    if (conversationId == null || _openingChat) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || user.emailConfirmedAt == null) return;
    _openingChat = true;
    pendingChatId.value = null;
    try {
      final resolved = await _resolveChat(conversationId, user.id);
      helbaNavigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => ChatPage(
              conversationId: conversationId,
              title: resolved.title,
              kind: resolved.kind,
              isAdmin: resolved.isAdmin)));
    } finally {
      _openingChat = false;
    }
  }

  Future<({String title, String kind, bool isAdmin})> _resolveChat(
      String conversationId, String myId) async {
    const fallback = (title: 'محادثة', kind: 'direct', isAdmin: false);
    try {
      final rows = await Supabase.instance.client
          .from('conversation_members')
          .select(
              'user_id,role,profiles(display_name,username),conversations(id,title,kind)')
          .eq('conversation_id', conversationId);
      final members = (rows as List).cast<Map<String, dynamic>>();
      if (members.isEmpty) return fallback;
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
      return fallback;
    }
  }

  Future<void> _load() async {
    try {
      boundEmail = await secureStore.read(key: 'helba_bound_email');
    } catch (_) {
      boundEmail = null;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _bind(String email) async {
    final normalized = normalizeEmail(email);
    try {
      await secureStore.write(key: 'helba_bound_email', value: normalized);
    } catch (_) {
      // A failed bind must not block sign-in; the next launch retries it.
    }
    if (mounted) setState(() => boundEmail = normalized);
  }

  Future<void> _loadMyProfile() async {
    try {
      final profile = await loadMyProfile();
      if (mounted) setState(() => _myProfile = profile);
    } catch (_) {
      // A missing or unloadable profile is treated as not-admin /
      // not-banned; the inbox still works, the admin panel stays hidden.
    } finally {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) {
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
              FilledButton(
                  onPressed: () =>
                      Supabase.instance.client.auth.signOut(),
                  child: const Text('تسجيل الخروج')),
            ]),
          )));
        }
        // Sign-up used to land straight in the inbox without confirming the
        // email, because only the sign-in path checked emailConfirmedAt.
        // Enforce confirmation here for every session, whatever created it.
        if (user.emailConfirmedAt == null) {
          return UnconfirmedEmailPage(email: email);
        }
        if (boundEmail == null && !_binding) {
          _binding = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _bind(email));
        }
        // Load the profile (admin / banned flags) when a different user
        // is seen; a missing row means not-admin / not-banned.
        if (_profileUserId != user.id && !_loadingProfile) {
          _loadingProfile = true;
          _profileUserId = user.id;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _loadMyProfile());
        }
        if (isBannedProfile(_myProfile)) {
          return const BannedAccountPage();
        }
        // Signed in and confirmed: listen for incoming calls. Idempotent
        // (the service subscribes once per user id); this only touches
        // the call service, never widget state, so it is safe in build().
        unawaited(CallService.instance.startListening());
        // Same pattern for push: register the FCM token and listen for
        // messages. Inert until Firebase is configured (see push.dart).
        unawaited(setupPushNotifications());
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
              onPressed: () => Supabase.instance.client.auth.signOut(),
              child: const Text('تسجيل الخروج')),
        ]),
      )));
}

class UnconfirmedEmailPage extends StatefulWidget {
  final String email;
  const UnconfirmedEmailPage({super.key, required this.email});
  @override
  State<UnconfirmedEmailPage> createState() => _UnconfirmedEmailPageState();
}

class _UnconfirmedEmailPageState extends State<UnconfirmedEmailPage> {
  bool busy = false;
  String? message;
  String? error;

  @override
  void initState() {
    super.initState();
    deepLinkError.addListener(_onDeepLinkError);
    // A link may already have failed before this screen appeared.
    if (deepLinkError.value != null) {
      error = deepLinkError.value;
    }
  }

  void _onDeepLinkError() {
    if (mounted && deepLinkError.value != null) {
      setState(() => error = deepLinkError.value);
    }
  }

  @override
  void dispose() {
    deepLinkError.removeListener(_onDeepLinkError);
    super.dispose();
  }

  Future<void> _resend() async {
    deepLinkError.value = null;
    setState(() {
      busy = true;
      message = null;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.resend(
          email: widget.email,
          type: OtpType.signup,
          emailRedirectTo: authCallbackUrl);
      if (mounted) {
        setState(
            () => message = 'أرسلنا رابط تأكيد جديد إلى بريدك الإلكتروني.');
      }
    } on AuthException catch (ex) {
      if (mounted) {
        setState(() => error = networkErrorMessage(ex) ?? ex.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = networkErrorMessage(e) ?? 'تعذر إرسال رابط التأكيد. حاول مجدداً.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
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
              onPressed: busy ? null : _resend,
              child: const Text('إعادة إرسال رابط التأكيد')),
          const SizedBox(height: 8),
          TextButton(
              onPressed: () => Supabase.instance.client.auth.signOut(),
              child: const Text('تسجيل الخروج')),
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

  @override
  void initState() {
    super.initState();
    if (widget.boundEmail != null) email.text = widget.boundEmail!;
  }

  @override
  void dispose() {
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
    setState(() {
      busy = true;
      error = null;
      message = null;
      errorDetail = null;
    });
    try {
      final auth = Supabase.instance.client.auth;
      if (signup) {
        final result = await auth.signUp(
            email: e,
            password: password.text,
            emailRedirectTo: authCallbackUrl);
        // If sign-up created a session (auto-confirm), drop it so the user
        // must confirm the email first; AuthGate enforces the same rule.
        if (result.session != null) {
          await auth.signOut();
        }
        setState(() => message = 'أرسلنا رابط تأكيد إلى بريدك الإلكتروني.');
      } else {
        final result =
            await auth.signInWithPassword(email: e, password: password.text);
        if (result.user?.emailConfirmedAt == null) {
          await auth.signOut();
          setState(
              () => error = 'أكد بريدك الإلكتروني أولاً من الرسالة التي وصلتك.');
        } else {
          await widget.onSignedIn(e);
        }
      }
    } on AuthException catch (ex) {
      final friendly = networkErrorMessage(ex);
      setState(() {
        error = friendly ?? ex.message;
        errorDetail = friendly == null ? null : ex.message;
      });
    } catch (e) {
      final friendly = networkErrorMessage(e);
      setState(() {
        error = friendly ?? 'تعذر الاتصال بالخدمة. حاول مجدداً.';
        errorDetail = friendly == null ? null : e.toString();
      });
    } finally {
      if (mounted) setState(() => busy = false);
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
                              setState(() {
                                busy = true;
                                error = null;
                                message = null;
                                errorDetail = null;
                              });
                              try {
                                await Supabase.instance.client.auth
                                    .resetPasswordForEmail(e,
                                        redirectTo: authCallbackUrl);
                                if (mounted) {
                                  setState(() => message =
                                      'إذا كان البريد مسجلاً فستصلك رسالة استعادة كلمة المرور.');
                                }
                              } on AuthException catch (ex) {
                                final friendly = networkErrorMessage(ex);
                                if (mounted) {
                                  setState(() {
                                    error = friendly ?? ex.message;
                                    errorDetail =
                                        friendly == null ? null : ex.message;
                                  });
                                }
                              } catch (e) {
                                final friendly = networkErrorMessage(e);
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
