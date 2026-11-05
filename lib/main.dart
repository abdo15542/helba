import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io' as io;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:native_flutter_proxy/native_flutter_proxy.dart';

const green = Color(0xFF087A4B);
const secureStore = FlutterSecureStorage();

/// Short commit SHA baked in at build time (the workflow passes
/// HELBA_COMMIT), shown on the login screen so a screenshot proves which
/// build is installed.
const buildCommit = String.fromEnvironment('HELBA_COMMIT', defaultValue: 'dev');

// Keyboards often auto-insert a space after '.' while typing an email
// (e.g. 'name@gmail. com'). trim() only removes the ends, so strip every
// whitespace character inside the address as well.
String normalizeEmail(String value) => value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// Friendly Arabic message for network failures; null for anything else.
/// Supabase surfaces network failures as an AuthException whose message
/// contains the underlying 'ClientException with SocketException...' text,
/// so detect by message content rather than by exception type.
String? networkErrorMessage(Object e) {
  if (e is io.SocketException) {
    return 'تعذّر الوصول إلى خادم هلبة. تحقق من اتصالك بالإنترنت وحاول مجدداً.';
  }
  final text = e is AuthException ? e.message : e.toString();
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup')) {
    return 'تعذّر الوصول إلى خادم هلبة. تحقق من اتصالك بالإنترنت وحاول مجدداً.';
  }
  return null;
}

// --- System proxy --------------------------------------------------------
// The phone's configured system proxy (WiFi or mobile APN), if any.
// Browsers use it; Dart's HttpClient does not read it on its own, so the
// app must ask the native side for it and apply it explicitly. On a
// network that only lets traffic out through its proxy, every direct
// connection fails while the browser works — exactly the symptom seen on
// this phone (system DNS fails, DoH fails, direct IPs fail).
String? _systemProxy;

/// Read the system proxy once ('host:port'), or null when none is set or
/// the native lookup is unavailable. Never throws.
Future<String?> readSystemProxy() async {
  try {
    final setting = await NativeProxyReader.proxySetting;
    if (!setting.enabled) return null;
    return '${setting.host}:${setting.port}';
  } catch (_) {
    return null;
  }
}

Future<void> _loadSystemProxy() async {
  try {
    _systemProxy = await readSystemProxy()
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    _systemProxy = null;
  }
}

// --- DNS-over-HTTPS fallback ---------------------------------------------
// Some networks (notably some mobile ISPs) fail to resolve *.supabase.co
// with the system resolver, while the same phone's browser — which uses
// DNS-over-HTTPS — reaches the server fine. To keep the app working on
// those networks, Supabase connections fall back to resolving the host
// over HTTPS (Google, then Cloudflare) and dialling the returned IP.
// TLS still verifies the original hostname, so nothing about security
// changes: the IP is only a dial address, never a trust anchor.

/// Hosts that get the DNS-over-HTTPS fallback when the system resolver fails.
bool needsDohFallback(String host) => host.endsWith('.supabase.co');

/// DoH endpoints are dialled by their well-known IP so the query itself
/// never depends on the system resolver; TLS still verifies the hostname.
const Map<String, List<String>> _dohBootstrapIps = {
  'dns.google': ['8.8.8.8', '8.8.4.4'],
  'cloudflare-dns.com': ['1.1.1.1', '1.0.0.1'],
};

/// Pull the IPv4 answers out of a DNS-over-HTTPS JSON response.
List<String> parseDohAnswers(Map<String, dynamic> json) {
  final answers = json['Answer'];
  if (answers is! List) return const [];
  final ips = <String>[];
  for (final a in answers) {
    if (a is Map && a['type'] == 1 && a['data'] is String) {
      ips.add(a['data'] as String);
    }
  }
  return ips;
}

/// Dial the first reachable IP in [ips]. A reachable anycast address
/// answers in well under a second; the timeout only bounds blackholed
/// addresses (some networks silently drop packets to DNS-server IPs).
Future<io.Socket> connectToFirstIp(
  List<String> ips,
  int port, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  Object? lastError;
  for (final ip in ips) {
    try {
      return await io.Socket.connect(ip, port).timeout(timeout);
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError ?? io.SocketException('Could not connect to $ips');
}

/// Last-resort dial addresses for a Supabase host, used only when both the
/// system resolver AND DNS-over-HTTPS fail. These are the host's own
/// Cloudflare edge IPs (its current A records) — the phone's browser
/// already proves TCP to them works, while some networks block the
/// well-known DNS-server IPs (8.8.8.8, 1.1.1.1) that DoH bootstraps from.
/// Cloudflare anycast IPs are stable for long periods, and every successful
/// DoH resolution refreshes the secure-storage cache below, so the seeds
/// only matter on a network where DoH is blocked too.
const Map<String, List<String>> seedIps = {
  'mpgnybncdiaaohjaqejq.supabase.co': ['104.18.38.10', '172.64.149.246'],
};

/// Persisted copy of the last IPs DoH resolved for a host, so a later
/// launch on a network where DoH is blocked can still dial the last
/// known-good addresses instead of failing outright.
Future<List<String>?> _readCachedIps(String host) async {
  try {
    final raw = await secureStore.read(key: 'helba_doh_ips_$host');
    if (raw == null) return null;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final at = DateTime.tryParse(decoded['at']?.toString() ?? '');
    if (at == null ||
        DateTime.now().difference(at) > const Duration(days: 7)) {
      return null;
    }
    final ips = decoded['ips'];
    if (ips is! List || ips.isEmpty) return null;
    return ips.map((e) => e.toString()).toList();
  } catch (_) {
    return null;
  }
}

Future<void> _writeCachedIps(String host, List<String> ips) async {
  try {
    await secureStore.write(
      key: 'helba_doh_ips_$host',
      value: jsonEncode({'ips': ips, 'at': DateTime.now().toIso8601String()}),
    );
  } catch (_) {
    // A failed cache write must never break the connection itself.
  }
}

final Map<String, ({List<String> ips, DateTime at})> _dohCache = {};
io.HttpClient? _dohClient;

/// Resolve [host] via DNS-over-HTTPS (Google first, Cloudflare second).
/// Results are cached in memory for 5 minutes and persisted for 7 days.
Future<List<String>> resolveViaDoh(String host) async {
  final cached = _dohCache[host];
  if (cached != null &&
      DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
    return cached.ips;
  }
  final client = _dohClient ??= io.HttpClient();
  Object? lastError;
  for (final base in [
    'https://dns.google/resolve',
    'https://cloudflare-dns.com/dns-query',
  ]) {
    try {
      final uri = Uri.parse('$base?name=$host&type=A');
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 4));
      request.headers.set('accept', 'application/dns-json');
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 4));
      final ips = parseDohAnswers(jsonDecode(body) as Map<String, dynamic>);
      if (ips.isNotEmpty) {
        _dohCache[host] = (ips: ips, at: DateTime.now());
        await _writeCachedIps(host, ips);
        return ips;
      }
    } catch (e) {
      // Keep the cause for the failure message below; try the next provider.
      lastError = e;
    }
  }
  // Keep the underlying cause in the message: without it the next failure
  // is undiagnosable (timeout? refused? TLS? blocked IP?).
  throw io.SocketException(
    'DNS-over-HTTPS resolution failed for $host (last error: $lastError)',
  );
}

Future<io.Socket> openSocketForUrl(Uri url) async {
  final host = url.host;
  final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
  final bootstrap = _dohBootstrapIps[host];
  if (bootstrap != null) {
    // A DoH endpoint itself: dial it by IP (short timeout — a working
    // anycast address answers fast, a blocked one just burns time).
    return connectToFirstIp(bootstrap, port,
        timeout: const Duration(seconds: 3));
  }
  if (!needsDohFallback(host)) {
    return io.Socket.connect(host, port);
  }
  // 1. The system resolver first — it works on most networks.
  Object? firstError;
  try {
    return await io.Socket.connect(host, port)
        .timeout(const Duration(seconds: 8));
  } catch (e) {
    firstError = e;
  }
  // 2. IPs resolved earlier and stored on the device (fast path for a
  // repeat launch on a network where DNS-over-HTTPS is blocked).
  final cached = await _readCachedIps(host);
  if (cached != null) {
    try {
      return await connectToFirstIp(cached, port,
          timeout: const Duration(seconds: 4));
    } catch (_) {
      // Stale cache entry; keep falling through to live resolution.
    }
  }
  // 3. Resolve over HTTPS (Google, then Cloudflare).
  Object? dohError;
  try {
    final ips = await resolveViaDoh(host);
    return await connectToFirstIp(ips, port);
  } catch (e) {
    // Both providers failed; the seed addresses are the last resort.
    dohError = e;
  }
  // 4. The host's own Cloudflare edge IPs (see seedIps). The phone's
  // browser proves these are reachable even where the DNS-server IPs
  // that DoH bootstraps from are blocked.
  final seed = seedIps[host];
  Object? seedError;
  if (seed != null) {
    try {
      final socket = await connectToFirstIp(seed, port,
          timeout: const Duration(seconds: 4));
      await _writeCachedIps(host, seed);
      return socket;
    } catch (e) {
      // Nothing left to try; report every failure below.
      seedError = e;
    }
  }
  // Report what was actually tried and why each step failed, instead of
  // rethrowing only the first error: a bare 'Failed host lookup' hides
  // whether the fallbacks even ran.
  throw io.SocketException(
    'Could not reach $host: system DNS failed ($firstError); '
    'DNS-over-HTTPS failed ($dohError); '
    'seed IPs failed ($seedError)',
  );
}

class HelbaHttpOverrides extends io.HttpOverrides {
  @override
  io.HttpClient createHttpClient(io.SecurityContext? context) {
    final client = super.createHttpClient(context);
    // When the phone has a system proxy (WiFi/APN), route every request
    // through it like the browser does. When there is none, leave the
    // default (environment proxy, if any) untouched.
    if (_systemProxy != null) {
      client.findProxy = (_) => 'PROXY $_systemProxy';
    }
    client.connectionFactory =
        (Uri url, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null) {
        // A proxy is configured (e.g. a sandbox or corporate network):
        // dial the proxy and let HttpClient perform the CONNECT tunnel as
        // usual. The proxy resolves the host, so the DoH fallback below
        // does not apply.
        try {
          return io.ConnectionTask.fromSocket(
              io.Socket.connect(proxyHost, proxyPort ?? 8080)
                  .timeout(const Duration(seconds: 10)),
              () {});
        } catch (e) {
          throw io.SocketException(
              'Could not reach proxy $proxyHost:${proxyPort ?? 8080}: $e');
        }
      }
      // No proxy: HttpClient upgrades the returned socket to TLS with
      // SNI/certificate checks for url.host.
      return io.ConnectionTask.fromSocket(openSocketForUrl(url), () {});
    };
    return client;
  }
}

/// Validate the configuration and initialize Supabase. Returns an Arabic
/// error message, or null when the app is ready to run. Kept separate from
/// main() so a failed start can be retried from the setup screen instead
/// of leaving the user on a dead end.
Future<String?> initializeHelba() async {
  const configuredUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://mpgnybncdiaaohjaqejq.supabase.co');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_IZ-P_b8LjdDfjATffyqqDg_yJOu9-Og');
  // Remove accidental spaces/newlines from build-time configuration before parsing the host.
  final url = configuredUrl.trim().replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'/+$'), '');
  final parsedUrl = Uri.tryParse(url);
  if (parsedUrl == null || parsedUrl.scheme != 'https' || parsedUrl.host.isEmpty) {
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Route Supabase traffic through the DNS-over-HTTPS fallback so the app
  // keeps working on networks whose system DNS cannot resolve Supabase.
  io.HttpOverrides.global = HelbaHttpOverrides();
  // Read the system proxy before any network client is created, so the app
  // routes through it exactly like the phone's browser does.
  await _loadSystemProxy();
  runApp(const HelbaApp());
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
    setState(() { _starting = true; _configError = null; });
    final error = await initializeHelba();
    if (mounted) setState(() { _starting = false; _configError = error; });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'هلبة',
    debugShowCheckedModeBanner: false,
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

  @override
  void initState() {
    super.initState();
    _load();
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

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) return LoginPage(boundEmail: boundEmail, onSignedIn: _bind);
        final email = normalizeEmail(user.email ?? '');
        if (boundEmail != null && boundEmail != email) {
          return Scaffold(body: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48, color: green),
              const SizedBox(height: 12),
              const Text('هذا التثبيت مرتبط ببريد آخر', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('تسجيل الخروج')),
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
        return const InboxPage();
      },
    );
  }
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

  Future<void> _resend() async {
    setState(() { busy = true; message = null; error = null; });
    try {
      await Supabase.instance.client.auth.resend(email: widget.email, type: OtpType.signup);
      if (mounted) setState(() => message = 'أرسلنا رابط تأكيد جديد إلى بريدك الإلكتروني.');
    } on AuthException catch (ex) {
      if (mounted) setState(() => error = networkErrorMessage(ex) ?? ex.message);
    } catch (e) {
      if (mounted) setState(() => error = networkErrorMessage(e) ?? 'تعذر إرسال رابط التأكيد. حاول مجدداً.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.mark_email_unread_outlined, size: 48, color: green),
      const SizedBox(height: 12),
      const Text('أكد بريدك الإلكتروني أولاً', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('أرسلنا رابط تأكيد إلى ${widget.email}. افتحه ثم سجل الدخول.', textAlign: TextAlign.center),
      if (message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!, style: const TextStyle(color: green))),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 16),
      FilledButton(onPressed: busy ? null : _resend, child: const Text('إعادة إرسال رابط التأكيد')),
      const SizedBox(height: 8),
      TextButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('تسجيل الخروج')),
    ]),
  )));
}

class SetupPage extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;
  const SetupPage({super.key, this.message, this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.settings_outlined, size: 48, color: green),
      const SizedBox(height: 12),
      Text(message ?? 'أضف SUPABASE_URL وSUPABASE_PUBLISHABLE_KEY لتفعيل هلبة.', textAlign: TextAlign.center),
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
  void dispose() { email.dispose(); password.dispose(); super.dispose(); }

  Future<void> submit() async {
    final e = normalizeEmail(email.text);
    if (!e.contains('@') || password.text.length < 8) {
      setState(() { error = 'أدخل بريداً صحيحاً وكلمة مرور من 8 أحرف على الأقل.'; errorDetail = null; });
      return;
    }
    if (widget.boundEmail != null && widget.boundEmail != e) {
      setState(() { error = 'هذا الجهاز مرتبط بالبريد ${widget.boundEmail} ولا يقبل بريداً آخر.'; errorDetail = null; });
      return;
    }
    setState(() { busy = true; error = null; message = null; errorDetail = null; });
    try {
      final auth = Supabase.instance.client.auth;
      if (signup) {
        final result = await auth.signUp(email: e, password: password.text);
        // If sign-up created a session (auto-confirm), drop it so the user
        // must confirm the email first; AuthGate enforces the same rule.
        if (result.session != null) {
          await auth.signOut();
        }
        setState(() => message = 'أرسلنا رابط تأكيد إلى بريدك الإلكتروني.');
      } else {
        final result = await auth.signInWithPassword(email: e, password: password.text);
        if (result.user?.emailConfirmedAt == null) {
          await auth.signOut();
          setState(() => error = 'أكد بريدك الإلكتروني أولاً من الرسالة التي وصلتك.');
        } else {
          await widget.onSignedIn(e);
        }
      }
    } on AuthException catch (ex) {
      final friendly = networkErrorMessage(ex);
      setState(() { error = friendly ?? ex.message; errorDetail = friendly == null ? null : ex.message; });
    } catch (e) {
      final friendly = networkErrorMessage(e);
      setState(() { error = friendly ?? 'تعذر الاتصال بالخدمة. حاول مجدداً.'; errorDetail = friendly == null ? null : e.toString(); });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.forum_rounded, color: green, size: 68),
          const SizedBox(height: 12),
          const Text('هلبة', textAlign: TextAlign.center, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900)),
          const Text('تواصل يجمعنا', textAlign: TextAlign.center),
          Text('الإصدار ${buildCommit.length >= 7 ? buildCommit.substring(0, 7) : buildCommit}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black45)),
          const SizedBox(height: 36),
          Text(signup ? 'إنشاء حساب جديد' : 'تسجيل الدخول', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'البريد الإلكتروني', prefixIcon: Icon(Icons.email_outlined), border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: password, obscureText: hidePassword, decoration: InputDecoration(labelText: 'كلمة المرور', prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(icon: Icon(hidePassword ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => hidePassword = !hidePassword)), border: const OutlineInputBorder())),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
          if (errorDetail != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(errorDetail!, style: const TextStyle(color: Colors.black54, fontSize: 12))),
          if (message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!, style: const TextStyle(color: green))),
          const SizedBox(height: 18),
          FilledButton(onPressed: busy ? null : submit, child: busy ? const CircularProgressIndicator() : Text(signup ? 'إنشاء الحساب' : 'دخول')),
          TextButton(onPressed: busy ? null : () => setState(() { signup = !signup; error = null; message = null; errorDetail = null; }), child: Text(signup ? 'لديك حساب؟ سجل الدخول' : 'ليس لديك حساب؟ أنشئ حساباً')),
          TextButton(onPressed: busy ? null : () async {
            final e = normalizeEmail(email.text);
            if (!e.contains('@')) {
              setState(() => error = 'أدخل بريدك الإلكتروني أولاً.');
              return;
            }
            setState(() { busy = true; error = null; message = null; errorDetail = null; });
            try {
              await Supabase.instance.client.auth.resetPasswordForEmail(e);
              if (mounted) setState(() => message = 'إذا كان البريد مسجلاً فستصلك رسالة استعادة كلمة المرور.');
            } on AuthException catch (ex) {
              final friendly = networkErrorMessage(ex);
              if (mounted) setState(() { error = friendly ?? ex.message; errorDetail = friendly == null ? null : ex.message; });
            } catch (e) {
              final friendly = networkErrorMessage(e);
              if (mounted) setState(() { error = friendly ?? 'تعذر إرسال رسالة الاستعادة. تحقق من الاتصال وحاول مجدداً.'; errorDetail = friendly == null ? null : e.toString(); });
            } finally {
              if (mounted) setState(() => busy = false);
            }
          }, child: const Text('نسيت كلمة المرور؟')),
        ],
      )),
    ))),
  );
}

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final search = TextEditingController();
  String query = '';
  // The chats future must live in state: creating it inside build() refetched
  // from Supabase on every rebuild, including every keystroke in search.
  late Future<List<Map<String, dynamic>>> _chatsFuture;

  @override
  void initState() {
    super.initState();
    _chatsFuture = loadChats();
  }

  Future<void> _refresh() async {
    final future = loadChats();
    if (mounted) setState(() => _chatsFuture = future);
    // Swallow here: the FutureBuilder above already surfaces the error.
    try { await future; } catch (_) {}
  }

  @override
  void dispose() { search.dispose(); super.dispose(); }

  Future<List<Map<String, dynamic>>> loadChats() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await Supabase.instance.client.from('conversation_members')
      .select('conversation_id, conversations(id,kind,title,updated_at,conversation_members(user_id,profiles(display_name,username)))')
      .eq('user_id', uid);
    final chats = rows.cast<Map<String, dynamic>>();
    // Newest conversation first; the query itself returns no ordering.
    chats.sort((a, b) {
      final aUpdated = (a['conversations'] as Map<String, dynamic>?)?['updated_at']?.toString() ?? '';
      final bUpdated = (b['conversations'] as Map<String, dynamic>?)?['updated_at']?.toString() ?? '';
      return bUpdated.compareTo(aUpdated);
    });
    return chats;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('هلبة', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, color: green)),
      actions: [IconButton(onPressed: () => Supabase.instance.client.auth.signOut(), icon: const Icon(Icons.logout))],
    ),
    floatingActionButton: FloatingActionButton.extended(
      backgroundColor: green, foregroundColor: Colors.white,
      onPressed: () => showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => const NewChatSheet()),
      icon: const Icon(Icons.add_comment_outlined), label: const Text('محادثة جديدة'),
    ),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: TextField(
        controller: search, onChanged: (v) => setState(() => query = v),
        decoration: InputDecoration(hintText: 'ابحث في محادثاتك', prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none)),
      )),
      Expanded(child: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _chatsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text('تعذر تحميل المحادثات: ${snap.error}'));
          final currentUserId = Supabase.instance.client.auth.currentUser?.id;
          final chats = (snap.data ?? []).where((r) {
            final c = r['conversations'] as Map<String, dynamic>?;
            final members = (c?['conversation_members'] as List<dynamic>? ?? []);
            final others = members.where((m) =>
              m is Map && m['user_id']?.toString() != currentUserId).toList();
            final other = others.isEmpty ? null : Map<String, dynamic>.from(others.first as Map);
            final profile = other?['profiles'] as Map<String, dynamic>?;
            final searchable = [
              c?['title']?.toString() ?? '',
              profile?['display_name']?.toString() ?? '',
              profile?['username']?.toString() ?? '',
            ].join(' ').toLowerCase();
            return searchable.contains(query.trim().toLowerCase());
          }).toList();
          if (chats.isEmpty) {
            return query.trim().isEmpty
                ? const _EmptyInbox()
                : const Center(child: Text('لا توجد نتائج مطابقة لبحثك.'));
          }
          return ListView.separated(
            itemCount: chats.length, separatorBuilder: (_, __) => const Divider(indent: 84, height: 1),
            itemBuilder: (context, i) {
              final c = chats[i]['conversations'] as Map<String, dynamic>;
              final members = (c['conversation_members'] as List<dynamic>? ?? []);
              final others = members.where((m) =>
                m is Map && m['user_id']?.toString() != currentUserId).toList();
              final other = others.isEmpty ? null : Map<String, dynamic>.from(others.first as Map);
              final profile = other?['profiles'] as Map<String, dynamic>?;
              final displayTitle = c['title']?.toString().trim().isNotEmpty == true
                  ? c['title'].toString()
                  : (profile?['display_name']?.toString().trim().isNotEmpty == true
                      ? profile!['display_name'].toString()
                      : (profile?['username']?.toString().isNotEmpty == true
                          ? '@${profile!['username']}'
                          : 'محادثة'));
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFFE1F1E8),
                  child: Icon(c['kind'] == 'group' ? Icons.groups_rounded : Icons.person, color: green),
                ),
                title: Text(displayTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(c['kind'] == 'group' ? 'مجموعة' : 'محادثة فردية'),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: c['id'].toString(), title: displayTitle))).then((_) => _refresh()),
              );
            },
          );
        },
      ))),
    ]),
  );
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();
  @override
  Widget build(BuildContext context) => const Center(child: Padding(
    padding: EdgeInsets.all(32),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.chat_bubble_outline, size: 58, color: green),
      SizedBox(height: 12),
      Text('لا توجد محادثات بعد', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      Text('ابدأ محادثة جديدة مع أحد مستخدمي هلبة.'),
    ]),
  ));
}

class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});
  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  final controller = TextEditingController();
  List<Map<String, dynamic>> users = [];
  final Set<String> selectedIds = {};
  final groupTitle = TextEditingController();
  bool busy = false;
  bool creatingGroup = false;
  String? error;

  int _searchRequest = 0;

  Future<void> findUsers(String value) async {
    final term = value.trim().replaceAll(RegExp(r'[,(){}]'), ' ');
    final request = ++_searchRequest;
    if (term.length < 2) {
      if (mounted) setState(() { users = []; busy = false; error = null; });
      return;
    }
    if (mounted) setState(() { busy = true; error = null; });
    try {
      final me = Supabase.instance.client.auth.currentUser!.id;
      final safeTerm = term.replaceAll('%', '').replaceAll('_', '');
      final result = await Supabase.instance.client.from('profiles')
        .select('id,display_name,username')
        .neq('id', me)
        .or('username.ilike.%$safeTerm%,display_name.ilike.%$safeTerm%')
        .limit(20);
      if (!mounted || request != _searchRequest) return;
      setState(() { users = result.cast<Map<String, dynamic>>(); error = null; });
    } catch (_) {
      if (mounted && request == _searchRequest) {
        setState(() => error = 'تعذر البحث عن المستخدمين.');
      }
    } finally {
      if (mounted && request == _searchRequest) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> createGroup() async {
    if (groupTitle.text.trim().length < 2 || selectedIds.isEmpty) {
      setState(() => error = 'اكتب اسم المجموعة واختر عضواً واحداً على الأقل.');
      return;
    }
    setState(() { busy = true; error = null; });
    try {
      final result = await Supabase.instance.client.rpc(
        'create_group_conversation',
        params: {'group_title': groupTitle.text.trim(), 'member_ids': selectedIds.toList()},
      );
      if (!mounted) return;
      final title = groupTitle.text.trim();
      Navigator.pop(context);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: result.toString(), title: title)));
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر إنشاء المجموعة. تأكد من تطبيق ترحيل قاعدة البيانات رقم 002.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startChat(Map<String, dynamic> user) async {
    setState(() => busy = true);
    try {
      final result = await Supabase.instance.client.rpc('create_direct_conversation', params: {'target_user': user['id']});
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: result.toString(), title: user['display_name']?.toString() ?? 'محادثة')));
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر إنشاء المحادثة. تحقق من إعداد قاعدة البيانات.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() { controller.dispose(); groupTitle.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Text(creatingGroup ? 'إنشاء مجموعة' : 'محادثة جديدة', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold))),
        TextButton.icon(
          onPressed: () => setState(() { creatingGroup = !creatingGroup; selectedIds.clear(); error = null; }),
          icon: Icon(creatingGroup ? Icons.person_outline : Icons.groups_outlined),
          label: Text(creatingGroup ? 'محادثة فردية' : 'مجموعة'),
        ),
      ]),
      if (creatingGroup) ...[
        const SizedBox(height: 10),
        TextField(controller: groupTitle, decoration: const InputDecoration(labelText: 'اسم المجموعة', border: OutlineInputBorder())),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 8),
      TextField(controller: controller, onChanged: findUsers, decoration: const InputDecoration(hintText: 'ابحث بالاسم أو اسم المستخدم', prefixIcon: Icon(Icons.search), border: OutlineInputBorder())),
      if (busy) const Padding(padding: EdgeInsets.all(10), child: LinearProgressIndicator()),
      if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
      Flexible(child: ListView(shrinkWrap: true, children: users.map((u) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: Text(u['display_name']?.toString() ?? ''),
        subtitle: Text('@${u['username'] ?? ''}'),
        trailing: creatingGroup ? Checkbox(
          value: selectedIds.contains(u['id'].toString()),
          onChanged: (checked) => setState(() {
            final id = u['id'].toString();
            if (checked == true) { selectedIds.add(id); } else { selectedIds.remove(id); }
          }),
        ) : null,
        onTap: () {
          if (creatingGroup) {
            setState(() {
              final id = u['id'].toString();
              if (!selectedIds.add(id)) selectedIds.remove(id);
            });
          } else {
            startChat(u);
          }
        },
      )).toList())),
      if (creatingGroup) Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: busy ? null : createGroup,
          icon: const Icon(Icons.group_add_outlined),
          label: Text('إنشاء المجموعة (${selectedIds.length})'),
        )),
      ),
    ]),
  );
}

class ChatPage extends StatefulWidget {
  final String conversationId, title;
  const ChatPage({super.key, required this.conversationId, required this.title});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final _scroll = ScrollController();
  bool sending = false;
  int _lastMessageCount = -1;
  final client = Supabase.instance.client;

  // The message stream must live in state: building it inside build() made
  // every rebuild (each send, each parent rebuild) resubscribe and flash
  // the list with a loading spinner.
  late final Stream<List<Map<String, dynamic>>> _messagesStream;
  Map<String, String> _memberNames = {};
  bool _isGroup = false;

  @override
  void initState() {
    super.initState();
    _messagesStream = client.from('messages').stream(primaryKey: ['id'])
      .eq('conversation_id', widget.conversationId).order('created_at');
    _loadMembers();
  }

  /// Member display names, so group messages show who wrote them.
  Future<void> _loadMembers() async {
    try {
      final rows = await client.from('conversation_members')
        .select('user_id,profiles(display_name,username)')
        .eq('conversation_id', widget.conversationId);
      final names = <String, String>{};
      for (final row in rows as List) {
        if (row is! Map) continue;
        final profile = row['profiles'] as Map<String, dynamic>?;
        final name = profile?['display_name']?.toString().trim().isNotEmpty == true
            ? profile!['display_name'].toString()
            : (profile?['username']?.toString().isNotEmpty == true
                ? '@${profile!['username']}'
                : '');
        if (name.isNotEmpty) names[row['user_id'].toString()] = name;
      }
      if (mounted) setState(() { _memberNames = names; _isGroup = names.length > 2; });
    } catch (_) {
      // Names are a nicety; messages still work without them.
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    if (extent > 0) _scroll.jumpTo(extent);
  }

  @override
  void dispose() { input.dispose(); _scroll.dispose(); super.dispose(); }


  String? _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'webp': return 'image/webp';
      case 'gif': return 'image/gif';
      case 'mp4': return 'video/mp4';
      case 'mov': return 'video/quicktime';
      case 'mp3': return 'audio/mpeg';
      case 'm4a': return 'audio/mp4';
      case 'aac': return 'audio/aac';
      case 'ogg': return 'audio/ogg';
      case 'wav': return 'audio/wav';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'zip': return 'application/zip';
      default: return null;
    }
  }

  Future<void> sendAttachment() async {
    if (sending) return;
    String? uploadedPath;
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final mime = _mimeFor(file.extension ?? '');
      if (mime == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('نوع الملف غير مدعوم. اختر صورة أو فيديو أو صوتاً أو PDF أو TXT أو ZIP.')),
          );
        }
        return;
      }
      const maxBytes = 50 * 1024 * 1024;
      if (file.size <= 0 || file.size > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يجب أن يكون حجم الملف أكبر من صفر ولا يتجاوز 50 ميغابايت.')),
          );
        }
        return;
      }
      final filePath = file.path;
      if (filePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر الوصول إلى الملف المحدد.')),
          );
        }
        return;
      }
      setState(() => sending = true);
      // Upload the file itself instead of reading up to 50 MB into memory
      // first; the old code held the whole file in RAM as bytes.
      final uid = client.auth.currentUser!.id;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path = '${widget.conversationId}/$uid/${DateTime.now().microsecondsSinceEpoch}_$safeName';
      await client.storage.from('helba-chat-media').upload(
        path, io.File(filePath), fileOptions: FileOptions(contentType: mime, upsert: false),
      );
      uploadedPath = path;
      final type = mime.startsWith('image/') ? 'image'
          : mime.startsWith('video/') ? 'video'
          : mime.startsWith('audio/') ? 'audio' : 'file';
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': file.name,
        'message_type': type,
        'attachment_path': path,
      });
      uploadedPath = null;
    } catch (_) {
      if (uploadedPath != null) {
        try {
          await client.storage.from('helba-chat-media').remove([uploadedPath]);
        } catch (_) {
          // Keep the original upload error; an orphan can be cleaned up later.
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر رفع الملف. تحقق من الاتصال ونوع الملف.')),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> openAttachment(String path) async {
    try {
      final url = await client.storage.from('helba-chat-media').createSignedUrl(path, 300);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح المرفق أو انتهت صلاحيته.')),
        );
      }
    }
  }

  Future<void> send() async {
    final body = input.text.trim();
    final uid = client.auth.currentUser?.id;
    if (body.isEmpty || sending || uid == null) return;
    if (body.length > 4000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحد الأقصى للرسالة 4000 حرف.')),
      );
      return;
    }
    setState(() => sending = true);
    try {
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': body,
        'message_type': 'text',
      });
      input.clear();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الرسالة.')));
    } finally { if (mounted) setState(() => sending = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _messagesStream,
          builder: (context, snap) {
            if (snap.hasError) return const Center(child: Text('تعذر تحميل الرسائل'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('ابدأ المحادثة برسالة ترحيب 👋'));
            if (rows.length != _lastMessageCount) {
              _lastMessageCount = rows.length;
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
            }
            return ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(14),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                final myId = client.auth.currentUser?.id;
                final mine = myId != null && row['sender_id'] == myId;
                final senderName = _memberNames[row['sender_id']?.toString()];
                final time = DateTime.tryParse(row['created_at']?.toString() ?? '');
                return Align(
                  alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: mine ? const Color(0xFFDDF3E6) : Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (!mine && _isGroup && senderName != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(senderName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: green)),
                        ),
                      if (row['attachment_path'] != null)
                        InkWell(
                          onTap: () => openAttachment(row['attachment_path'].toString()),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.attach_file, size: 18, color: green),
                            const SizedBox(width: 5),
                            Flexible(child: Text(row['body']?.toString() ?? 'مرفق', style: const TextStyle(decoration: TextDecoration.underline))),
                            const SizedBox(width: 5),
                            const Icon(Icons.download_rounded, size: 17, color: green),
                          ]),
                        )
                      else
                        Text(row['body']?.toString() ?? ''),
                      if (time != null) Text(DateFormat('HH:mm').format(time.toLocal()), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                    ]),
                  ),
                );
              },
            );
          },
        )),
        SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(children: [
            IconButton(
              tooltip: 'إرفاق ملف',
              onPressed: sending ? null : sendAttachment,
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4, decoration: InputDecoration(hintText: 'اكتب رسالة...', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none)))),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: sending ? null : send, icon: const Icon(Icons.send), style: IconButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white)),
          ]),
        )),
      ]),
    );
  }
}
