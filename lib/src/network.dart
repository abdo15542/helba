import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:native_flutter_proxy/native_flutter_proxy.dart';

import 'config.dart';

// --- System proxy --------------------------------------------------------
// The phone's configured system proxy (WiFi or mobile APN), if any.
// Browsers use it; Dart's HttpClient does not read it on its own, so the
// app must ask the native side for it and apply it explicitly. On a
// network that only lets traffic out through its proxy, every direct
// connection fails while the browser works — exactly the symptom seen on
// this phone (system DNS fails, DoH fails, direct IPs fail).
String? _systemProxy;

/// The system proxy loaded at startup ('host:port'), or null when none is
/// set. Read by the diagnostics screen to show what the app is using.
String? get currentSystemProxy => _systemProxy;

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

/// Load the system proxy into [_systemProxy] before any network client is
/// created. Never throws; a failed lookup simply means "no proxy".
Future<void> loadSystemProxy() async {
  try {
    _systemProxy =
        await readSystemProxy().timeout(const Duration(seconds: 2));
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
  supabaseHost: ['104.18.38.10', '172.64.149.246'],
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
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 4));
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

/// Open a socket for [url] and, for https/wss, upgrade it to TLS with SNI
/// and certificate checks for the URL host. This must be done here:
/// HttpClient does NOT upgrade the socket a custom connectionFactory
/// returns — it uses it exactly as-is (dart:io _ConnectionTarget only
/// calls SecureSocket.startConnect in the default path). Sending the raw
/// socket for an https URL means plain HTTP bytes reach the server's
/// HTTPS port, which answers with an HTML '400 The plain HTTP request
/// was sent to HTTPS port' page — the exact failure the signup probe
/// showed on the device.
Future<io.Socket> _connectSecurely(Uri url) async {
  final socket = await openSocketForUrl(url);
  if (url.scheme != 'https' && url.scheme != 'wss') return socket;
  try {
    // No onBadCertificate callback: the platform's trusted roots decide,
    // and an invalid certificate must fail rather than be accepted.
    return await io.SecureSocket.secure(
      socket,
      host: url.host,
    ).timeout(const Duration(seconds: 15));
  } catch (e) {
    // A failed handshake leaves a half-open socket behind; close it so a
    // retry starts clean.
    try {
      socket.destroy();
    } catch (_) {}
    rethrow;
  }
}

class HelbaHttpOverrides extends io.HttpOverrides {
  @override
  io.HttpClient createHttpClient(io.SecurityContext? context) {
    final client = super.createHttpClient(context);
    // Identify as a normal browser client (see browserUserAgent): some
    // networks answer Dart's default agent with an HTML challenge page
    // instead of the JSON Supabase returns.
    client.userAgent = browserUserAgent;
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
        // dial the proxy and let HttpClient perform the CONNECT tunnel and
        // the TLS upgrade itself, as usual. The proxy resolves the host,
        // so the DoH fallback below does not apply.
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
      // No proxy: connect directly and upgrade to TLS ourselves (see
      // _connectSecurely — HttpClient will not do it for us).
      return io.ConnectionTask.fromSocket(_connectSecurely(url), () {});
    };
    return client;
  }
}
