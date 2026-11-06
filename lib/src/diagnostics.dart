import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'config.dart';
import 'network.dart';

/// The outcome of one network check.
enum CheckStatus { running, passed, failed }

/// Arabic label for a check status.
String checkStatusLabel(CheckStatus status) => switch (status) {
      CheckStatus.running => 'جارٍ…',
      CheckStatus.passed => 'ناجح',
      CheckStatus.failed => 'فاشل',
    };

/// User-facing detail for a check failure. A bare `TimeoutException`
/// string tells the user nothing; label timeouts plainly as
/// "انتهت المهلة" (M19) so a slow network reads as a slow network,
/// not as an unknown error.
String diagnosticErrorDetail(Object e) {
  if (e is TimeoutException) {
    return 'انتهت المهلة (تجاوز الفحص الحد الزمني المسموح)';
  }
  return e.toString();
}

/// Human-readable description of the system proxy in use.
String describeProxy(String? proxy) =>
    proxy == null ? 'لا يوجد بروكسي' : 'البروكسي: $proxy';

/// Human-readable description of resolved addresses.
String describeAddresses(List<io.InternetAddress> addresses) =>
    addresses.isEmpty
        ? 'لم يتم العثور على عناوين'
        : addresses.map((a) => a.address).join(', ');

/// True when a response body is JSON (Supabase's real answer), false when
/// it is an HTML page from bot protection or an ISP middlebox standing in
/// for the server — the case that makes signup fail with
/// 'Failed to decode error response'.
bool isJsonResponseBody(String body) => body.trimLeft().startsWith('{');

class DiagnosticResult {
  const DiagnosticResult({
    required this.title,
    required this.status,
    required this.detail,
  });

  final String title;
  final CheckStatus status;
  final String detail;
}

/// On-demand network diagnostics: runs the same connection steps the app
/// itself uses to reach Supabase and shows each result honestly, so a
/// failure names the exact step that broke instead of a generic message.
class NetworkDiagnosticsPage extends StatefulWidget {
  const NetworkDiagnosticsPage({super.key});

  @override
  State<NetworkDiagnosticsPage> createState() =>
      _NetworkDiagnosticsPageState();
}

class _NetworkDiagnosticsPageState extends State<NetworkDiagnosticsPage> {
  static const _titles = [
    'البروكسي',
    'DNS النظام',
    'DNS عبر HTTPS',
    'الاتصال المباشر بعنوان الخادم',
    'الوصول إلى Supabase Auth',
    'فحص التسجيل',
  ];

  List<DiagnosticResult> _results = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  // M19: the six checks are independent, so they run concurrently
  // (Future.wait) under one overall 60s budget instead of serially
  // (~150s worst case). Each check still has its own 25s cap in
  // _runOne; the overall budget is a backstop. If it fires, any check
  // still running is marked "انتهت المهلة"; a late check may still
  // replace its row with its real result when it finishes (up to its
  // own 25s cap) — that is honest, not a bug.
  Future<void> _runChecks() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results = _titles
          .map((t) => DiagnosticResult(
              title: t, status: CheckStatus.running, detail: ''))
          .toList();
    });
    try {
      await Future.wait([
        _runOne(0, _checkProxy),
        _runOne(1, _checkSystemDns),
        _runOne(2, _checkDoh),
        _runOne(3, _checkSeedDial),
        _runOne(4, _checkAuthHealth),
        _runOne(5, _checkSignupProbe),
      ]).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      if (mounted) {
        setState(() {
          for (var i = 0; i < _results.length; i++) {
            if (_results[i].status == CheckStatus.running) {
              _results[i] = DiagnosticResult(
                title: _titles[i],
                status: CheckStatus.failed,
                detail: 'انتهت المهلة (تجاوز الفحص الإجمالي 60 ثانية)',
              );
            }
          }
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runOne(
      int index, Future<DiagnosticResult> Function() check) async {
    DiagnosticResult result;
    try {
      result = await check().timeout(const Duration(seconds: 25));
    } on TimeoutException {
      result = DiagnosticResult(
        title: _titles[index],
        status: CheckStatus.failed,
        detail: 'انتهت المهلة (تجاوز الفحص 25 ثانية)',
      );
    } catch (e) {
      result = DiagnosticResult(
        title: _titles[index],
        status: CheckStatus.failed,
        detail: diagnosticErrorDetail(e),
      );
    }
    if (!mounted) return;
    setState(() => _results[index] = result);
  }

  Future<DiagnosticResult> _checkProxy() async {
    final proxy = await readSystemProxy();
    if (proxy == null) {
      return DiagnosticResult(
        title: _titles[0],
        status: CheckStatus.passed,
        detail: describeProxy(proxy),
      );
    }
    // B19: previously this check always passed without ever touching
    // the proxy. Now it really dials the proxy and asks it for a
    // CONNECT tunnel to the Supabase host — a proxy that refuses (or
    // is unreachable) must fail this check.
    final split = proxy.lastIndexOf(':');
    if (split <= 0) {
      return DiagnosticResult(
        title: _titles[0],
        status: CheckStatus.failed,
        detail: 'صيغة بروكسي غير صالحة: $proxy',
      );
    }
    final proxyHost = proxy.substring(0, split);
    final proxyPort = int.tryParse(proxy.substring(split + 1));
    if (proxyPort == null) {
      return DiagnosticResult(
        title: _titles[0],
        status: CheckStatus.failed,
        detail: 'منفذ بروكسي غير صالح: $proxy',
      );
    }
    try {
      final socket = await io.Socket.connect(proxyHost, proxyPort)
          .timeout(const Duration(seconds: 10));
      try {
        socket.write(
          'CONNECT $supabaseHost:443 HTTP/1.1\r\n'
          'Host: $supabaseHost:443\r\n\r\n',
        );
        final firstChunk = await socket.first.timeout(
          const Duration(seconds: 10),
        );
        final statusLine =
            utf8.decode(firstChunk, allowMalformed: true).split('\r\n').first;
        if (RegExp(r'^HTTP/\d(\.\d)? 2\d\d').hasMatch(statusLine)) {
          return DiagnosticResult(
            title: _titles[0],
            status: CheckStatus.passed,
            detail: 'البروكسي: $proxy\nقبل CONNECT إلى $supabaseHost:443 '
                '($statusLine)',
          );
        }
        return DiagnosticResult(
          title: _titles[0],
          status: CheckStatus.failed,
          detail: 'البروكسي: $proxy\nرفض CONNECT إلى $supabaseHost:443 '
              '($statusLine)',
        );
      } finally {
        socket.destroy();
      }
    } catch (e) {
      return DiagnosticResult(
        title: _titles[0],
        status: CheckStatus.failed,
        detail: 'البروكسي: $proxy\nتعذر الاتصال بالبروكسي: '
            '${diagnosticErrorDetail(e)}',
      );
    }
  }

  Future<DiagnosticResult> _checkSystemDns() async {
    try {
      final addresses = await io.InternetAddress.lookup(supabaseHost)
          .timeout(const Duration(seconds: 10));
      if (addresses.isEmpty) {
        return DiagnosticResult(
          title: _titles[1],
          status: CheckStatus.failed,
          detail: 'لم يتم العثور على عناوين',
        );
      }
      return DiagnosticResult(
        title: _titles[1],
        status: CheckStatus.passed,
        detail: describeAddresses(addresses),
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[1],
        status: CheckStatus.failed,
        detail: diagnosticErrorDetail(e),
      );
    }
  }

  Future<DiagnosticResult> _checkDoh() async {
    try {
      final ips = await resolveViaDoh(supabaseHost);
      return DiagnosticResult(
        title: _titles[2],
        status: CheckStatus.passed,
        detail: ips.join(', '),
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[2],
        status: CheckStatus.failed,
        detail: diagnosticErrorDetail(e),
      );
    }
  }

  Future<DiagnosticResult> _checkSeedDial() async {
    // B19: previously this dialled ONE hardcoded IP ('172.64.149.246')
    // with TCP only. Now it tries every seed address for the host and
    // completes a real TLS handshake (SNI + certificate check for the
    // Supabase host) before passing — a TCP connect alone proves
    // nothing about reaching Supabase.
    final seeds = seedIps[supabaseHost] ?? const <String>[];
    if (seeds.isEmpty) {
      return DiagnosticResult(
        title: _titles[3],
        status: CheckStatus.failed,
        detail: 'لا توجد عناوين أولية لـ $supabaseHost',
      );
    }
    Object? lastError;
    for (final seedIp in seeds) {
      try {
        final socket = await connectToFirstIp(
          [seedIp],
          443,
          timeout: const Duration(seconds: 5),
        );
        try {
          final secure = await io.SecureSocket.secure(
            socket,
            host: supabaseHost,
          ).timeout(const Duration(seconds: 15));
          secure.destroy();
        } catch (e) {
          try {
            socket.destroy();
          } catch (_) {}
          rethrow;
        }
        return DiagnosticResult(
          title: _titles[3],
          status: CheckStatus.passed,
          detail: 'تم الاتصال بـ $seedIp:443 وإتمام TLS لـ $supabaseHost',
        );
      } catch (e) {
        lastError = e;
      }
    }
    return DiagnosticResult(
      title: _titles[3],
      status: CheckStatus.failed,
      detail: 'فشل الاتصال بكل العناوين الأولية '
          '(${seeds.join(', ')}): ${diagnosticErrorDetail(lastError!)}',
    );
  }

  Future<DiagnosticResult> _checkAuthHealth() async {
    final client = io.HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('https://$supabaseHost/auth/v1/health'))
          .timeout(const Duration(seconds: 15));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final status = response.statusCode;
      // B5: GoTrue GET /auth/v1/health returns 200 with JSON when the
      // server is healthy. The old check (400 || 401) failed on a
      // healthy server. Status alone is still not enough: a plain-HTTP
      // request to the HTTPS port also answers 400 (nginx's HTML error
      // page). The body must be Supabase's JSON for the check to mean
      // anything.
      final passed =
          status >= 200 && status < 300 && isJsonResponseBody(body);
      return DiagnosticResult(
        title: _titles[4],
        status: passed ? CheckStatus.passed : CheckStatus.failed,
        detail:
            'رمز الحالة: $status\n${body.length > 200 ? '${body.substring(0, 200)}…' : body}',
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[4],
        status: CheckStatus.failed,
        detail: diagnosticErrorDetail(e),
      );
    } finally {
      client.close();
    }
  }

  Future<DiagnosticResult> _checkSignupProbe() async {
    // Probe the exact endpoint signup uses, with a deliberately invalid
    // email, so no account is ever created. A healthy path returns a
    // JSON 400 ('Unable to validate email address'); an HTML body means
    // something on the network (bot protection / an ISP page) is
    // answering in place of Supabase — which is exactly what makes
    // signup fail with 'Failed to decode error response'.
    final client = io.HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse('https://$supabaseHost/auth/v1/signup'))
          .timeout(const Duration(seconds: 15));
      request.headers.set('apikey', supabasePublishableKey);
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'email': 'diagnostic-invalid',
        'password': 'DiagnosticProbe123!',
      }));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final snippet =
          body.length > 200 ? '${body.substring(0, 200)}…' : body;
      final status = response.statusCode;
      // M24: previously ANY JSON body passed — a 429 (rate-limited) or
      // 500 JSON error counted as "ناجح". Only the expected 400
      // validation error ('Unable to validate email address') proves the
      // signup path works; a 429 is surfaced distinctly so the user
      // knows to wait instead of retrying into the limit.
      if (status == 429) {
        return DiagnosticResult(
          title: _titles[5],
          status: CheckStatus.failed,
          detail: 'رمز الحالة: 429 (تم تقييد الطلبات — أعد المحاولة لاحقاً)\n'
              '$snippet',
        );
      }
      return DiagnosticResult(
        title: _titles[5],
        status: (status == 400 && isJsonResponseBody(body))
            ? CheckStatus.passed
            : CheckStatus.failed,
        detail: 'رمز الحالة: $status\n$snippet',
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[5],
        status: CheckStatus.failed,
        detail: diagnosticErrorDetail(e),
      );
    } finally {
      client.close();
    }
  }

  Color _statusColor(CheckStatus status) => switch (status) {
        CheckStatus.running => Colors.black45,
        CheckStatus.passed => green,
        CheckStatus.failed => Colors.red,
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تشخيص الشبكة')),
        body: Column(children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final result = _results[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(
                              result.title,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                          Text(
                            checkStatusLabel(result.status),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _statusColor(result.status),
                            ),
                          ),
                        ]),
                        if (result.detail.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          SelectableText(
                            result.detail,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _running ? null : _runChecks,
                child: const Text('إعادة الفحص'),
              ),
            ),
          ),
        ]),
      );
}
