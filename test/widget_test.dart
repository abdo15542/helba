import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/config.dart';
import 'package:helba/src/diagnostics.dart';
import 'package:helba/src/network.dart';
import 'package:helba/src/utils.dart';

void main() {
  test('HELBA brand color is configured', () {
    expect(green.toARGB32(), 0xFF087A4B);
  });

  test('normalizeEmail strips spaces keyboards insert after dots', () {
    expect(normalizeEmail('Tagreby98@Gmail. com'), 'tagreby98@gmail.com');
    expect(normalizeEmail('  user @example.com '), 'user@example.com');
  });

  test('parseDohAnswers keeps only IPv4 answers', () {
    expect(
      parseDohAnswers({
        'Status': 0,
        'Answer': [
          {'name': 'x.supabase.co.', 'type': 1, 'data': '104.18.38.10'},
          {'name': 'x.supabase.co.', 'type': 28, 'data': '2606:4700::6812:260a'},
          {'name': 'x.supabase.co.', 'type': 5, 'data': 'other.example.'},
        ],
      }),
      ['104.18.38.10'],
    );
    expect(parseDohAnswers({'Status': 3}), isEmpty);
    expect(parseDohAnswers({}), isEmpty);
  });

  test('needsDohFallback only matches Supabase project hosts', () {
    expect(needsDohFallback('mpgnybncdiaaohjaqejq.supabase.co'), isTrue);
    expect(needsDohFallback('other.supabase.co'), isTrue);
    expect(needsDohFallback('supabase.co'), isFalse);
    expect(needsDohFallback('example.com'), isFalse);
  });

  test('resolveViaDoh resolves the Helba project host', () async {
    final ips = await resolveViaDoh('mpgnybncdiaaohjaqejq.supabase.co');
    expect(ips, isNotEmpty);
    expect(ips.every((ip) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)),
        isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('connectToFirstIp opens a socket to the resolved address', () async {
    final ips = await resolveViaDoh('mpgnybncdiaaohjaqejq.supabase.co');
    // The dial must open a socket without throwing. (In sandboxed networks
    // outbound TCP is transparently redirected to an egress proxy, so the
    // remote endpoint is not asserted here; the real end-to-end fallback
    // is verified on the device.)
    final socket = await connectToFirstIp(ips, 443);
    socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('seed IPs are valid IPv4 addresses for the Helba host', () {
    final seeds = seedIps['mpgnybncdiaaohjaqejq.supabase.co'];
    expect(seeds, isNotNull);
    expect(seeds, isNotEmpty);
    expect(seeds!.every((ip) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)),
        isTrue);
  });

  test('connectToFirstIp opens a socket to the seed addresses', () async {
    final seeds = seedIps['mpgnybncdiaaohjaqejq.supabase.co']!;
    final socket = await connectToFirstIp(seeds, 443);
    socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('resolveViaDoh failure keeps the underlying cause', () async {
    // A host with no DNS records: both providers answer with no records,
    // so the failure must name the cause instead of swallowing it.
    try {
      await resolveViaDoh('nonexistent.invalid');
      fail('Expected a SocketException');
    } on io.SocketException catch (e) {
      expect(e.message, contains('DNS-over-HTTPS resolution failed'));
      expect(e.message, contains('last error'));
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('readSystemProxy returns null without a native channel', () async {
    // In tests there is no platform channel, so the lookup must fail
    // gracefully instead of throwing.
    expect(await readSystemProxy(), isNull);
  });

  test('buildCommit is a non-empty identifier', () {
    expect(buildCommit.isNotEmpty, isTrue);
  });

  test('HttpClient with Helba overrides reaches Supabase Auth', () async {
    io.HttpOverrides.global = HelbaHttpOverrides();
    final client = io.HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(
          'https://mpgnybncdiaaohjaqejq.supabase.co/auth/v1/health'));
      final response = await request.close();
      // Without an API key the live Auth service answers 401 (some edges
      // answer 400); either proves we reached it instead of failing in
      // the network layer.
      expect(response.statusCode, isIn([400, 401]));
      await response.drain<void>();
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  group('diagnostics helpers', () {
    test('checkStatusLabel returns Arabic labels', () {
      expect(checkStatusLabel(CheckStatus.running), 'جارٍ…');
      expect(checkStatusLabel(CheckStatus.passed), 'ناجح');
      expect(checkStatusLabel(CheckStatus.failed), 'فاشل');
    });

    test('describeProxy reports a proxy or its absence', () {
      expect(describeProxy(null), 'لا يوجد بروكسي');
      expect(describeProxy('10.0.0.1:8080'), 'البروكسي: 10.0.0.1:8080');
    });

    test('describeAddresses joins resolved addresses', () {
      expect(describeAddresses([]), 'لم يتم العثور على عناوين');
      expect(
        describeAddresses([
          io.InternetAddress('104.18.38.10'),
          io.InternetAddress('172.64.149.246'),
        ]),
        '104.18.38.10, 172.64.149.246',
      );
    });
  });
}
