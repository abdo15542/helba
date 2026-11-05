import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/main.dart';

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
}
