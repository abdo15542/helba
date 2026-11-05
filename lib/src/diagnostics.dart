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

/// Human-readable description of the system proxy in use.
String describeProxy(String? proxy) =>
    proxy == null ? 'لا يوجد بروكسي' : 'البروكسي: $proxy';

/// Human-readable description of resolved addresses.
String describeAddresses(List<io.InternetAddress> addresses) =>
    addresses.isEmpty
        ? 'لم يتم العثور على عناوين'
        : addresses.map((a) => a.address).join(', ');

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
  ];

  List<DiagnosticResult> _results = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results = _titles
          .map((t) => DiagnosticResult(
              title: t, status: CheckStatus.running, detail: ''))
          .toList();
    });
    await _runOne(0, _checkProxy);
    await _runOne(1, _checkSystemDns);
    await _runOne(2, _checkDoh);
    await _runOne(3, _checkSeedDial);
    await _runOne(4, _checkAuthHealth);
    if (mounted) setState(() => _running = false);
  }

  Future<void> _runOne(
      int index, Future<DiagnosticResult> Function() check) async {
    DiagnosticResult result;
    try {
      result = await check().timeout(const Duration(seconds: 25));
    } catch (e) {
      result = DiagnosticResult(
        title: _titles[index],
        status: CheckStatus.failed,
        detail: e.toString(),
      );
    }
    if (!mounted) return;
    setState(() => _results[index] = result);
  }

  Future<DiagnosticResult> _checkProxy() async {
    final proxy = await readSystemProxy();
    return DiagnosticResult(
      title: _titles[0],
      status: CheckStatus.passed,
      detail: describeProxy(proxy),
    );
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
        detail: e.toString(),
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
        detail: e.toString(),
      );
    }
  }

  Future<DiagnosticResult> _checkSeedDial() async {
    const seedIp = '172.64.149.246';
    try {
      final socket = await connectToFirstIp(
        [seedIp],
        443,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      return DiagnosticResult(
        title: _titles[3],
        status: CheckStatus.passed,
        detail: 'تم الاتصال بـ $seedIp:443',
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[3],
        status: CheckStatus.failed,
        detail: e.toString(),
      );
    }
  }

  Future<DiagnosticResult> _checkAuthHealth() async {
    final client = io.HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('https://$supabaseHost/auth/v1/health'))
          .timeout(const Duration(seconds: 15));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      final status = response.statusCode;
      final passed = status == 400 || status == 401;
      return DiagnosticResult(
        title: _titles[4],
        status: passed ? CheckStatus.passed : CheckStatus.failed,
        detail: 'رمز الحالة: $status',
      );
    } catch (e) {
      return DiagnosticResult(
        title: _titles[4],
        status: CheckStatus.failed,
        detail: e.toString(),
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
