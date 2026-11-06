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
///
/// NOT const: the key is [supabaseHost], derived at runtime from the
/// effective Supabase URL (config.dart, B12), so the map is built once
/// at startup from that single source of truth.
final Map<String, List<String>> seedIps = {
  supabaseHost: ['104.18.38.10', '172.64.149.246'],
};

/// How long a persisted cache entry is trusted: DoH-resolved addresses
/// for 7 days; seed addresses (never DoH-resolved, see [decodeCachedDohEntry])
/// for only 6 hours, so a stale seed can never masquerade as a fresh
/// resolution (M21).
const Duration _resolvedCacheTtl = Duration(days: 7);
const Duration _seedCacheTtl = Duration(hours: 6);

/// Decode one persisted DoH cache entry (the JSON written by
/// [_writeCachedIps]). Returns the IPs plus whether they are seed
/// addresses, or null when the entry is malformed or expired.
///
/// Pure function (takes [now] explicitly) so the TTL rules are
/// unit-testable. Entries written before the `seed` marker existed
/// decode as `seed: false` (they were written only by live DoH).
({List<String> ips, bool seed})? decodeCachedDohEntry(
  String raw,
  DateTime now,
) {
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final at = DateTime.tryParse(decoded['at']?.toString() ?? '');
    final ips = decoded['ips'];
    if (at == null || ips is! List || ips.isEmpty) return null;
    final seed = decoded['seed'] == true;
    final ttl = seed ? _seedCacheTtl : _resolvedCacheTtl;
    if (now.difference(at) > ttl) return null;
    return (ips: ips.map((e) => e.toString()).toList(), seed: seed);
  } catch (_) {
    return null;
  }
}

/// Persisted copy of the last IPs DoH resolved for a host, so a later
/// launch on a network where DoH is blocked can still dial the last
/// known-good addresses instead of failing outright.
Future<({List<String> ips, bool seed})?> _readCachedIps(
  String host,
) async {
  try {
    final raw = await secureStore.read(key: 'helba_doh_ips_$host');
    if (raw == null) return null;
    return decodeCachedDohEntry(raw, DateTime.now());
  } catch (_) {
    return null;
  }
}

Future<void> _writeCachedIps(
  String host,
  List<String> ips, {
  bool seed = false,
}) async {
  try {
    await secureStore.write(
      key: 'helba_doh_ips_$host',
      value: jsonEncode({
        'ips': ips,
        'at': DateTime.now().toIso8601String(),
        // Seed addresses are NOT DoH-resolved: mark them so they are
        // only ever a last resort, with the short TTL above (M21).
        'seed': seed,
      }),
    );
  } catch (_) {
    // A failed cache write must never break the connection itself.
  }
}

final Map<String, ({List<String> ips, DateTime at})> _dohCache = {};
io.HttpClient? _dohClient;

/// Close the shared DNS-over-HTTPS [io.HttpClient], releasing its
/// sockets. Call it when the app detaches (e.g. from the root widget's
/// [WidgetsBindingObserver.didChangeAppLifecycleState] on `detached`,
/// or from `main()`'s teardown path) — the client is lazily recreated
/// by [resolveViaDoh] on the next resolution, so closing it is always
/// safe. (M29: previously the shared client was never closed.)
/// NOTE: this lives in network.dart because main.dart owns the call
/// site; see the coordinator report for the exact wiring.
void closeDohClient() {
  _dohClient?.close();
  _dohClient = null;
}

/// Validate one decoded DNS-over-HTTPS JSON response. Returns null when
/// the response is a usable answer (HTTP 200, DoH `Status` 0, at least
/// one A record), otherwise a human-readable reason the answer must be
/// rejected. Pure function, so the empty-answer rules are unit-testable.
///
/// A DoH provider answers NXDOMAIN/SERVFAIL with HTTP 200 and
/// `Status: 3` (or 2) and no `Answer` section — without this check an
/// empty answer looked like success and the caller was left with the
/// useless "last error: null" (M20).
String? dohErrorForResponse({
  required int statusCode,
  required Map<String, dynamic> json,
  required String provider,
  required String host,
}) {
  if (statusCode != 200) {
    return 'DoH $provider returned HTTP $statusCode for $host';
  }
  final dohStatus = json['Status'];
  if (dohStatus is int && dohStatus != 0) {
    return 'DoH $provider returned Status $dohStatus for $host '
        '(no usable answer: 2 = SERVFAIL, 3 = NXDOMAIN)';
  }
  if (parseDohAnswers(json).isEmpty) {
    return 'DoH $provider returned no A records for $host';
  }
  return null;
}

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
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      // M20: a non-200 status, a non-zero DoH Status (NXDOMAIN/SERVFAIL),
      // or an empty Answer section is a failed resolution, not a success
      // with zero addresses — record the reason so the caller never ends
      // up with the useless "last error: null".
      final answerError = dohErrorForResponse(
        statusCode: response.statusCode,
        json: decoded,
        provider: base,
        host: host,
      );
      if (answerError != null) {
        lastError = io.SocketException(answerError);
        continue;
      }
      final ips = parseDohAnswers(decoded);
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

/// Complete with the first [attempts] future that succeeds; if every
/// attempt fails, complete with the last error. Unlike [Future.any],
/// a fast failure does NOT cancel the race — the other attempts still
/// get their chance. A socket that wins after another attempt already
/// won is destroyed so it cannot leak.
Future<io.Socket> _firstSuccess(List<Future<io.Socket>> attempts) async {
  final completer = Completer<io.Socket>();
  var remaining = attempts.length;
  Object? lastError;
  for (final attempt in attempts) {
    attempt.then(
      (socket) {
        if (completer.isCompleted) {
          socket.destroy();
        } else {
          completer.complete(socket);
        }
      },
      onError: (Object e) {
        lastError = e;
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.completeError(lastError!);
        }
      },
    );
  }
  return completer.future;
}

/// Overall budget for the whole Supabase fallback chain in
/// [openSocketForUrl]: the old chain could burn ~60s+ per request
/// (system DNS 8s, cached IPs, DoH ~12s per provider, DoH connect,
/// seeds). The caller (HttpClient) gets a failure after this long
/// instead of hanging the login spinner indefinitely (B17).
const Duration openSocketOverallTimeout = Duration(seconds: 20);

Future<io.Socket> openSocketForUrl(Uri url) async {
  // onTimeout (not a catch on TimeoutException): an inner step's own
  // timeout must never be mislabelled as the overall budget expiring.
  // NOTE: the inner attempts keep running briefly in the background
  // (Dart has no cancellation); a late winner is destroyed by
  // _firstSuccess, and a late plain connect is left to finish harmlessly.
  return _openSocketForUrlInner(url).timeout(
    openSocketOverallTimeout,
    onTimeout: () => throw io.SocketException(
      'Timed out after ${openSocketOverallTimeout.inSeconds}s while '
      'reaching ${url.host} (system DNS, DoH and seed fallbacks did not '
      'answer in time)',
    ),
  );
}

Future<io.Socket> _openSocketForUrlInner(Uri url) async {
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
    // B18: previously this had no timeout at all — only the TLS
    // handshake in _connectSecurely was bounded, so a blackholed TCP
    // connect to a non-Supabase host could hang indefinitely.
    return io.Socket.connect(host, port)
        .timeout(const Duration(seconds: 10));
  }
  // 1. The system resolver first — it works on most networks.
  Object? firstError;
  try {
    return await io.Socket.connect(host, port)
        .timeout(const Duration(seconds: 8));
  } catch (e) {
    firstError = e;
  }
  // 2. Live DoH and the persisted cache race each other (B17/M21):
  // live DoH is tried FIRST in effect — a stale 7-day cache entry is
  // never allowed to delay a fresh resolution. The cache gets only a
  // 1–2s head start: whichever answers first wins. Seed-marked cache
  // entries are excluded here; they are a last resort (step 3).
  final cached = await _readCachedIps(host);
  final cachedResolved =
      (cached != null && !cached.seed) ? cached.ips : null;
  Future<io.Socket> liveDohAttempt() async {
    final ips = await resolveViaDoh(host);
    return connectToFirstIp(ips, port);
  }

  Future<io.Socket> cachedAttempt() async {
    if (cachedResolved == null) {
      throw io.SocketException('No cached IPs for $host');
    }
    return connectToFirstIp(cachedResolved, port,
        timeout: const Duration(seconds: 2));
  }

  Object? dohError;
  try {
    return await _firstSuccess([liveDohAttempt(), cachedAttempt()]);
  } catch (e) {
    // Both live DoH and the cache failed; seeds are the last resort.
    dohError = e;
  }
  // 3. Seed addresses, in order: persisted seed cache entries first
  // (short TTL, seed-marked), then the hardcoded [seedIps].
  // M21: seeds are NEVER written back as if DoH-resolved — they are
  // persisted with seed: true and the short TTL, so they stay a last
  // resort and can never outrank a fresh DoH answer.
  Object? seedError;
  final seedAttempts = <List<String>>[];
  if (cached != null && cached.seed) seedAttempts.add(cached.ips);
  final seed = seedIps[host];
  if (seed != null) seedAttempts.add(seed);
  for (final seedIpsToTry in seedAttempts) {
    try {
      final socket = await connectToFirstIp(seedIpsToTry, port,
          timeout: const Duration(seconds: 4));
      await _writeCachedIps(host, seedIpsToTry, seed: true);
      return socket;
    } catch (e) {
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

/// True for loopback destinations (M22): a system proxy must never be
/// used for them — the proxy cannot reach the device itself, and routing
/// local traffic out to a proxy breaks on-device servers and tests.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]';
}

/// True when [e] looks like a DNS failure ("Failed host lookup") rather
/// than a refused/timed-out TCP connect. Only a DNS-looking failure is
/// worth retrying via DoH: retrying a refused proxy over DoH would just
/// dial the same unreachable proxy a second time.
bool _looksLikeDnsFailure(Object e) =>
    e.toString().contains('Failed host lookup');

/// Dial a proxy host, falling back to DNS-over-HTTPS when the system
/// resolver cannot resolve the proxy's hostname (M22). The proxy host
/// is usually a LAN address (direct connect succeeds), so the DoH path
/// only runs on a DNS-looking failure, bounded to ~10s.
Future<io.Socket> _connectToProxy(String proxyHost, int proxyPort) async {
  Object? directError;
  try {
    return await io.Socket.connect(proxyHost, proxyPort)
        .timeout(const Duration(seconds: 10));
  } catch (e) {
    directError = e;
    if (!_looksLikeDnsFailure(e)) rethrow;
  }
  try {
    final ips = await resolveViaDoh(proxyHost)
        .timeout(const Duration(seconds: 10));
    return await connectToFirstIp(ips, proxyPort,
        timeout: const Duration(seconds: 4));
  } catch (e) {
    throw io.SocketException(
      'Could not reach proxy $proxyHost:$proxyPort: direct ($directError); '
      'DoH fallback ($e)',
    );
  }
}

/// HTTP overrides routing Supabase traffic through the DoH fallback.
///
/// F59 (VERIFIED — see the review report for the full evidence):
/// `WebSocket.connect` DOES honour these overrides in this Dart SDK
/// (3.13.7). `dart:_http/websocket_impl.dart:1310` keeps a single
/// lazily-initialised `static final HttpClient _httpClient = HttpClient();`
/// and `connect()` (line 1312) uses `(customClient ?? _httpClient)`; the
/// `HttpClient()` factory (`http.dart:1348-1353`) consults
/// `HttpOverrides.current` at construction time, and main.dart sets
/// `HttpOverrides.global` before any Supabase/Realtime use, so the
/// lazily-created static client is built by [createHttpClient] below.
/// The chain is: realtime_client `createWebSocketClient`
/// (`websocket_io.dart`) → `IOWebSocketChannel.connect` (no customClient)
/// → `WebSocket.connect` → this connectionFactory → [_connectSecurely]
/// → [openSocketForUrl] (DoH fallback + TLS). No custom Realtime
/// transport is needed; `RealtimeClientOptions.transport` exists as a
/// fallback if that ever changes.
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
    // NOTE (M22, startup part): [_systemProxy] is still loaded once at
    // startup by loadSystemProxy(); re-reading it on connectivity
    // changes is a main.dart concern and is NOT done here — this file
    // must not touch main.dart.
    if (_systemProxy != null) {
      client.findProxy = (_) => 'PROXY $_systemProxy';
    }
    client.connectionFactory =
        (Uri url, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null && !isLoopbackHost(url.host)) {
        // A proxy is configured (e.g. a sandbox or corporate network):
        // dial the proxy and let HttpClient perform the CONNECT tunnel and
        // the TLS upgrade itself, as usual. The proxy resolves the
        // target host, so the DoH fallback for the target does not apply
        // — but the PROXY host itself is resolved via DoH when the
        // system resolver fails for it (see _connectToProxy).
        // The 8080 default applies only when proxyPort is genuinely
        // absent (HttpClient passes null then); a configured port is
        // always honoured.
        try {
          return io.ConnectionTask.fromSocket(
              _connectToProxy(proxyHost, proxyPort ?? 8080), () {});
        } catch (e) {
          throw io.SocketException(
              'Could not reach proxy $proxyHost:${proxyPort ?? 8080}: $e');
        }
      }
      // No proxy (or a loopback destination, which bypasses the proxy):
      // connect directly and upgrade to TLS ourselves (see
      // _connectSecurely — HttpClient will not do it for us).
      return io.ConnectionTask.fromSocket(_connectSecurely(url), () {});
    };
    return client;
  }
}
