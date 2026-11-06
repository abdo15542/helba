import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/config.dart';
import 'package:helba/src/diagnostics.dart';
import 'package:helba/src/network.dart';

void main() {
  group('dohErrorForResponse (M20)', () {
    const host = 'mpgnybncdiaaohjaqejq.supabase.co';
    const provider = 'https://dns.google/resolve';

    test('accepts a 200 / Status 0 answer with A records', () {
      expect(
        dohErrorForResponse(
          statusCode: 200,
          json: {
            'Status': 0,
            'Answer': [
              {'name': '$host.', 'type': 1, 'data': '104.18.38.10'},
            ],
          },
          provider: provider,
          host: host,
        ),
        isNull,
      );
    });

    test('rejects a non-200 HTTP status', () {
      final error = dohErrorForResponse(
        statusCode: 500,
        json: {'Status': 0, 'Answer': []},
        provider: provider,
        host: host,
      );
      expect(error, contains('HTTP 500'));
    });

    test('rejects NXDOMAIN (Status 3) with no Answer section', () {
      final error = dohErrorForResponse(
        statusCode: 200,
        json: {'Status': 3},
        provider: provider,
        host: host,
      );
      expect(error, contains('Status 3'));
      expect(error, contains('NXDOMAIN'));
    });

    test('rejects SERVFAIL (Status 2)', () {
      expect(
        dohErrorForResponse(
          statusCode: 200,
          json: {'Status': 2},
          provider: provider,
          host: host,
        ),
        contains('Status 2'),
      );
    });

    test('rejects a 200 / Status 0 answer with no A records', () {
      expect(
        dohErrorForResponse(
          statusCode: 200,
          json: {
            'Status': 0,
            'Answer': [
              {'name': '$host.', 'type': 28, 'data': '2606:4700::6812:260a'},
            ],
          },
          provider: provider,
          host: host,
        ),
        contains('no A records'),
      );
    });
  });

  group('decodeCachedDohEntry seed/cache TTL (M21)', () {
    final now = DateTime.utc(2026, 11, 6, 12);
    String entry(List<String> ips, DateTime at, {bool? seed}) => jsonEncode({
          'ips': ips,
          'at': at.toIso8601String(),
          if (seed != null) 'seed': seed,
        });

    test('fresh DoH-resolved entry decodes with seed false', () {
      final decoded = decodeCachedDohEntry(
        entry(['1.2.3.4'], now.subtract(const Duration(days: 6))),
        now,
      );
      expect(decoded, isNotNull);
      expect(decoded!.ips, ['1.2.3.4']);
      expect(decoded.seed, isFalse);
    });

    test('DoH-resolved entry older than 7 days is expired', () {
      expect(
        decodeCachedDohEntry(
          entry(['1.2.3.4'], now.subtract(const Duration(days: 8))),
          now,
        ),
        isNull,
      );
    });

    test('seed entry is marked seed and trusted within 6 hours', () {
      final decoded = decodeCachedDohEntry(
        entry(['104.18.38.10'], now.subtract(const Duration(hours: 5)),
            seed: true),
        now,
      );
      expect(decoded, isNotNull);
      expect(decoded!.seed, isTrue);
    });

    test('seed entry older than 6 hours is expired (short TTL)', () {
      expect(
        decodeCachedDohEntry(
          entry(['104.18.38.10'], now.subtract(const Duration(hours: 7)),
              seed: true),
          now,
        ),
        isNull,
      );
    });

    test('legacy entry without a seed marker decodes as resolved', () {
      final decoded = decodeCachedDohEntry(
        entry(['1.2.3.4'], now.subtract(const Duration(hours: 1))),
        now,
      );
      expect(decoded, isNotNull);
      expect(decoded!.seed, isFalse);
    });

    test('malformed entries decode to null', () {
      expect(decodeCachedDohEntry('not json', now), isNull);
      expect(decodeCachedDohEntry('{"ips": []}', now), isNull);
      expect(decodeCachedDohEntry('{"at": "junk", "ips": ["1.2.3.4"]}', now),
          isNull);
    });
  });

  group('isLoopbackHost (M22)', () {
    test('loopback names and addresses bypass the proxy', () {
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('LOCALHOST'), isTrue);
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('[::1]'), isTrue);
    });

    test('remote and LAN hosts do not bypass the proxy', () {
      expect(isLoopbackHost('mpgnybncdiaaohjaqejq.supabase.co'), isFalse);
      expect(isLoopbackHost('192.168.1.1'), isFalse);
      expect(isLoopbackHost('10.0.0.5'), isFalse);
      expect(isLoopbackHost('example.com'), isFalse);
    });
  });

  group('supabaseHost derivation (B12)', () {
    test('host is derived from the effective Supabase URL', () {
      expect(supabaseHost, Uri.parse(supabaseUrl).host);
      expect(supabaseHost, isNotEmpty);
    });

    test('seed IPs are keyed by the derived host', () {
      final seeds = seedIps[supabaseHost];
      expect(seeds, isNotNull);
      expect(seeds, hasLength(2));
      expect(
        seeds!.every((ip) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)),
        isTrue,
      );
    });

    test('default URL and default host agree', () {
      expect(Uri.parse(supabaseUrlDefault).host, supabaseHostDefault);
    });
  });

  group('diagnosticErrorDetail (M19)', () {
    test('labels a TimeoutException as "انتهت المهلة"', () {
      expect(
        diagnosticErrorDetail(TimeoutException('slow')),
        contains('انتهت المهلة'),
      );
    });

    test('passes other errors through unchanged', () {
      expect(
        diagnosticErrorDetail(Exception('boom')),
        contains('boom'),
      );
    });
  });

  test('closeDohClient is safe with no client yet (M29)', () {
    // Must not throw when the shared DoH client was never created;
    // resolveViaDoh recreates it lazily on the next resolution.
    closeDohClient();
    closeDohClient();
  });

  test('isDevBuild matches the dev fallback (M28)', () {
    expect(isDevBuild, buildCommit == 'dev');
  });
}
