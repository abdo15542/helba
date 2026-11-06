import 'dart:convert';
import 'dart:io' as io;

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/admin.dart';
import 'package:helba/src/calls.dart';
import 'package:helba/src/channels.dart';
import 'package:helba/src/config.dart';
import 'package:helba/src/deeplink.dart';
import 'package:helba/src/diagnostics.dart';
import 'package:helba/src/e2ee.dart';
import 'package:helba/src/network.dart';
import 'package:helba/src/push.dart';
import 'package:helba/src/stories.dart';
import 'package:helba/src/utils.dart';

/// True when the process runs behind a proxy (sandboxed environment):
/// direct TCP is intercepted there, so tests that need a direct TLS
/// handshake cannot run and must skip instead of failing.
bool get _hasProxyEnvironment {
  final env = io.Platform.environment;
  return env['https_proxy'] != null ||
      env['HTTPS_PROXY'] != null ||
      env['http_proxy'] != null ||
      env['HTTP_PROXY'] != null;
}

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
      final body = await response.transform(utf8.decoder).join();
      // Without an API key the live Auth service answers 401 (some edges
      // answer 400); either proves we reached it instead of failing in
      // the network layer. The body must be Supabase's JSON — a status
      // alone also matches nginx's HTML 'plain HTTP on HTTPS port' page.
      expect(response.statusCode, isIn([400, 401]));
      expect(body.trimLeft().startsWith('{'), isTrue);
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Helba overrides perform a real TLS handshake (no plain HTTP)',
      () async {
    // A direct network path is required: in a sandboxed environment the
    // egress proxy intercepts TCP, so no TLS handshake can complete.
    // On CI (no proxy variables) the test runs for real.
    if (_hasProxyEnvironment) {
      markTestSkipped('Direct network path unavailable in this environment');
      return;
    }
    io.HttpOverrides.global = HelbaHttpOverrides();
    final client = io.HttpClient();
    // Force the direct path (no environment proxy): this is the path the
    // phone takes, and the one that used to send plain HTTP to port 443.
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(Uri.parse(
          'https://mpgnybncdiaaohjaqejq.supabase.co/auth/v1/health'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, isIn([400, 401]));
      // Before the TLS fix the server answered with nginx's HTML
      // '400 The plain HTTP request was sent to HTTPS port' page.
      expect(body.trimLeft().startsWith('{'), isTrue);
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('signup probe reaches Supabase as JSON, not an HTML error page',
      () async {
    if (_hasProxyEnvironment) {
      markTestSkipped('Direct network path unavailable in this environment');
      return;
    }
    io.HttpOverrides.global = HelbaHttpOverrides();
    final client = io.HttpClient();
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.postUrl(Uri.parse(
          'https://mpgnybncdiaaohjaqejq.supabase.co/auth/v1/signup'));
      request.headers.set('apikey', supabasePublishableKey);
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'email': 'diagnostic-invalid',
        'password': 'DiagnosticProbe123!',
      }));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 400);
      expect(body.trimLeft().startsWith('{'), isTrue);
      expect(body, contains('Unable to validate email address'));
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Helba overrides identify as a browser client', () {
    final client = HelbaHttpOverrides().createHttpClient(null);
    expect(client.userAgent, browserUserAgent);
    expect(client.userAgent, contains('Mozilla/5.0'));
    client.close();
  });

  test('networkErrorMessage explains undecodable server replies', () {
    expect(
      networkErrorMessage(Exception('Failed to decode error response')),
      isNotNull,
    );
    expect(
      networkErrorMessage(Exception('Failed to decode error response')),
      contains('غير متوقع'),
    );
    expect(
      networkErrorMessage(Exception('Received an empty response')),
      isNotNull,
    );
    expect(networkErrorMessage(Exception('something else')), isNull);
  });

  group('deep links', () {
    test('authCallbackUrl is the app callback', () {
      expect(authCallbackUrl, 'helba://auth/callback');
    });

    test('isAuthCallback accepts only the app auth callback', () {
      expect(isAuthCallback(Uri.parse('helba://auth/callback')), isTrue);
      expect(
          isAuthCallback(Uri.parse(
              'helba://auth/callback?code=abc&state=xyz')),
          isTrue);
      expect(isAuthCallback(Uri.parse('helba://auth/reset')), isFalse);
      expect(
          isAuthCallback(
              Uri.parse('helba://auth/reset?code=abc')),
          isTrue);
      expect(isAuthCallback(Uri.parse('helba://other/callback')), isFalse);
      expect(
          isAuthCallback(Uri.parse('https://example.com/auth/callback')),
          isFalse);
    });
  });

  group('push helpers', () {
    test('parseChatDeepLink accepts only helba://chat/<id>', () {
      expect(
          parseChatDeepLink(Uri.parse(
              'helba://chat/123e4567-e89b-12d3-a456-426614174000')),
          '123e4567-e89b-12d3-a456-426614174000');
      expect(parseChatDeepLink(Uri.parse('helba://auth/callback')), isNull);
      expect(parseChatDeepLink(Uri.parse('https://example.com/chat/abc')),
          isNull);
      expect(parseChatDeepLink(Uri.parse('helba://chat/')), isNull);
      expect(parseChatDeepLink(Uri.parse('helba://chat/a/b')), isNull);
      expect(parseChatDeepLink(Uri.parse('helba://other/abc')), isNull);
    });

    test('isChatDeepLink / chatIdFromDeepLink agree with parseChatDeepLink',
        () {
      const uuid = '123e4567-e89b-12d3-a456-426614174000';
      final chat = Uri.parse('helba://chat/$uuid');
      expect(isChatDeepLink(chat), isTrue);
      expect(chatIdFromDeepLink(chat), uuid);
      // A non-UUID id is not a chat link (B-2): it would make PostgREST
      // answer 400, so it is rejected before it is queued.
      final bad = Uri.parse('helba://chat/abc-123');
      expect(isChatDeepLink(bad), isFalse);
      expect(chatIdFromDeepLink(bad), isNull);
      final auth = Uri.parse('helba://auth/callback');
      expect(isChatDeepLink(auth), isFalse);
      expect(chatIdFromDeepLink(auth), isNull);
    });

    test('buildNotificationTitle falls back to the app name', () {
      expect(buildNotificationTitle('أحمد'), 'أحمد');
      expect(buildNotificationTitle('  أحمد  '), 'أحمد');
      expect(buildNotificationTitle(''), 'هلبة');
      expect(buildNotificationTitle('   '), 'هلبة');
      expect(buildNotificationTitle(null), 'هلبة');
    });

    test('buildNotificationBody truncates long text to ~100 chars', () {
      final long = 'a' * 150;
      final body = buildNotificationBody(long, 'text');
      expect(body.length, pushPreviewMaxLength + 1);
      expect(body, endsWith('…'));
      expect(body, startsWith('a' * pushPreviewMaxLength));
      final exact = 'b' * pushPreviewMaxLength;
      expect(buildNotificationBody(exact, 'text'), exact);
      expect(buildNotificationBody('مرحباً', 'text'), 'مرحباً');
    });

    test('buildNotificationBody falls back for empty body / attachments',
        () {
      expect(buildNotificationBody('', 'text'), 'رسالة جديدة');
      expect(buildNotificationBody(null, 'text'), 'رسالة جديدة');
      expect(buildNotificationBody('   ', null), 'رسالة جديدة');
      expect(buildNotificationBody('photo.jpg', 'image'), 'صورة');
      expect(buildNotificationBody('clip.mp4', 'video'), 'فيديو');
      expect(buildNotificationBody('voice.mp3', 'audio'), 'ملف صوتي');
      expect(buildNotificationBody('doc.pdf', 'file'), 'ملف');
    });

    test('isValidPushToken rejects empty / blank tokens', () {
      expect(isValidPushToken(''), isFalse);
      expect(isValidPushToken('   '), isFalse);
      expect(isValidPushToken(null), isFalse);
      expect(isValidPushToken('eXaMpLeToKeN:APA91b...'), isTrue);
    });
  });

  group('stories helpers', () {
    final created = DateTime.utc(2026, 11, 5, 10);
    final expires = created.add(const Duration(hours: 24));
    Map<String, dynamic> storyRow(DateTime expiresAt) => {
          'id': 'story-1',
          'user_id': 'user-1',
          'media_url': 'user-1/123_photo.jpg',
          'media_type': 'image',
          'created_at': created.toIso8601String(),
          'expires_at': expiresAt.toIso8601String(),
        };

    test('isStoryExpired: +23h is not expired, +25h is expired', () {
      expect(
          isStoryExpired(
              storyRow(expires), created.add(const Duration(hours: 23))),
          isFalse);
      expect(
          isStoryExpired(
              storyRow(expires), created.add(const Duration(hours: 25))),
          isTrue);
    });

    test('isStoryExpired: exactly at expiry is expired', () {
      expect(isStoryExpired(storyRow(expires), expires), isTrue);
      expect(
          isStoryExpired(
              storyRow(expires), expires.subtract(const Duration(seconds: 1))),
          isFalse);
    });

    test('isStoryExpired: an unparsable expiry is treated as expired', () {
      expect(isStoryExpired({'expires_at': 'not-a-date'}, created), isTrue);
      expect(isStoryExpired({}, created), isTrue);
    });

    test('filterUnexpiredStories keeps only unexpired stories', () {
      final rows = [
        storyRow(created.add(const Duration(hours: 24))),
        storyRow(created.add(const Duration(hours: 1))),
        storyRow(created.add(const Duration(hours: 48))),
      ];
      final now = created.add(const Duration(hours: 23));
      expect(filterUnexpiredStories(rows, now), hasLength(2));
      expect(filterUnexpiredStories(rows, now).map((r) => r['expires_at']),
          contains(rows[0]['expires_at']));
    });

    test('storyMediaTypeFromMime maps image/video, rejects the rest', () {
      expect(storyMediaTypeFromMime('image/jpeg'), 'image');
      expect(storyMediaTypeFromMime('image/png'), 'image');
      expect(storyMediaTypeFromMime('video/mp4'), 'video');
      expect(storyMediaTypeFromMime('video/quicktime'), 'video');
      expect(storyMediaTypeFromMime('application/pdf'), isNull);
      expect(storyMediaTypeFromMime('audio/mpeg'), isNull);
      expect(storyMediaTypeFromMime(null), isNull);
    });
  });

  group('channels helpers', () {
    test('canPostInConversation: only channel admins post', () {
      expect(canPostInConversation('channel', 'member'), isFalse);
      expect(canPostInConversation('channel', 'admin'), isTrue);
      expect(canPostInConversation('channel', null), isFalse);
      expect(canPostInConversation('group', 'member'), isTrue);
      expect(canPostInConversation('group', 'admin'), isTrue);
      expect(canPostInConversation('direct', 'member'), isTrue);
      expect(canPostInConversation('direct', 'admin'), isTrue);
      // Unknown kinds default to allowed, never silently lock the composer.
      expect(canPostInConversation('unknown', 'member'), isTrue);
      expect(canPostInConversation(null, 'member'), isTrue);
    });

    test('isChannelKind matches only channel', () {
      expect(isChannelKind('channel'), isTrue);
      expect(isChannelKind('group'), isFalse);
      expect(isChannelKind('direct'), isFalse);
      expect(isChannelKind(null), isFalse);
    });

    test('joinableChannels filters out joined, non-public, non-channel rows',
        () {
      final rows = [
        {
          'id': 'c1',
          'kind': 'channel',
          'is_public': true,
          'conversation_members': [
            {'user_id': 'other'}
          ],
        },
        {
          'id': 'c2',
          'kind': 'channel',
          'is_public': true,
          'conversation_members': [
            {'user_id': 'me'},
            {'user_id': 'other'}
          ],
        },
        {
          'id': 'c3',
          'kind': 'channel',
          'is_public': false,
          'conversation_members': [],
        },
        {
          'id': 'c4',
          'kind': 'group',
          'is_public': true,
          'conversation_members': [],
        },
        {
          'id': 'c5',
          'kind': 'channel',
          'is_public': true,
          'conversation_members': [],
        },
      ];
      final joinable = joinableChannels(rows, 'me');
      expect(joinable.map((r) => r['id']), ['c1', 'c5']);
    });

    test('roleInConversation reads the embedded member role', () {
      final row = {
        'conversation_members': [
          {'user_id': 'me', 'role': 'admin'},
          {'user_id': 'other', 'role': 'member'},
        ],
      };
      expect(roleInConversation(row, 'me'), 'admin');
      expect(roleInConversation(row, 'other'), 'member');
      expect(roleInConversation(row, 'nobody'), 'member');
      expect(roleInConversation({}, 'me'), 'member');
    });

    test('channelSubtitle returns Arabic labels', () {
      expect(channelSubtitle('channel'), 'قناة');
      expect(channelSubtitle('group'), 'مجموعة');
      expect(channelSubtitle('direct'), 'محادثة فردية');
      expect(channelSubtitle(null), 'محادثة فردية');
    });
  });

  group('admin helpers', () {
    test('isAdminProfile / isBannedProfile / canSeeAdminPanel', () {
      expect(isAdminProfile({'is_admin': true}), isTrue);
      expect(isAdminProfile({'is_admin': false}), isFalse);
      expect(isAdminProfile({}), isFalse);
      expect(isAdminProfile(null), isFalse);
      expect(isBannedProfile({'is_banned': true}), isTrue);
      expect(isBannedProfile({'is_banned': false}), isFalse);
      expect(isBannedProfile({}), isFalse);
      expect(isBannedProfile(null), isFalse);
      expect(canSeeAdminPanel({'is_admin': true}), isTrue);
      expect(canSeeAdminPanel({'is_admin': false}), isFalse);
      expect(canSeeAdminPanel(null), isFalse);
    });

    test('reportStatusLabel covers all statuses plus unknown', () {
      expect(reportStatusLabel('pending'), 'قيد المراجعة');
      expect(reportStatusLabel('reviewed'), 'تمت المراجعة');
      expect(reportStatusLabel('dismissed'), 'تم التجاهل');
      expect(reportStatusLabel('something-else'), 'قيد المراجعة');
      expect(reportStatusLabel(null), 'قيد المراجعة');
    });

    test('isValidReportTarget matrix', () {
      const uuid = '123e4567-e89b-12d3-a456-426614174000';
      expect(isValidReportTarget('message', uuid), isTrue);
      expect(isValidReportTarget('user', uuid), isTrue);
      expect(isValidReportTarget('post', uuid), isFalse);
      expect(isValidReportTarget('comment', uuid), isFalse);
      expect(isValidReportTarget(null, uuid), isFalse);
      expect(isValidReportTarget('message', ''), isFalse);
      expect(isValidReportTarget('message', null), isFalse);
      expect(isValidReportTarget('message', 'not-a-uuid'), isFalse);
      expect(isValidReportTarget('message', '  $uuid  '), isTrue);
    });

    test('sortReports puts pending first, then newest', () {
      final rows = [
        {
          'id': 'r1',
          'status': 'reviewed',
          'created_at': '2026-11-05T10:00:00Z'
        },
        {
          'id': 'r2',
          'status': 'pending',
          'created_at': '2026-11-05T09:00:00Z'
        },
        {
          'id': 'r3',
          'status': 'pending',
          'created_at': '2026-11-05T11:00:00Z'
        },
      ];
      expect(
          sortReports(rows).map((r) => r['id']), ['r3', 'r2', 'r1']);
    });
  });

  group('calls signalling helpers', () {
    const offer = {
      'type': 'offer',
      'from': 'caller-id',
      'to': 'callee-id',
      'callId': 'call-1',
      'callType': 'video',
      'payload': {'sdp': 'v=0...', 'type': 'offer'},
    };

    test('parseCallSignal parses a valid offer', () {
      final signal = parseCallSignal(offer);
      expect(signal, isNotNull);
      expect(signal!.type, CallSignalType.offer);
      expect(signal.from, 'caller-id');
      expect(signal.to, 'callee-id');
      expect(signal.callId, 'call-1');
      expect(signal.callType, 'video');
      expect(signal.sdp, 'v=0...');
      expect(signal.sdpType, 'offer');
    });

    test('parseCallSignal parses answer, ice, hangup and decline', () {
      final answer = parseCallSignal({
        'type': 'answer',
        'from': 'callee-id',
        'to': 'caller-id',
        'callId': 'call-1',
        'callType': 'voice',
        'payload': {'sdp': 'v=0...', 'type': 'answer'},
      });
      expect(answer?.type, CallSignalType.answer);
      expect(answer?.sdpType, 'answer');

      final ice = parseCallSignal({
        'type': 'ice',
        'from': 'caller-id',
        'to': 'callee-id',
        'callId': 'call-1',
        'callType': 'voice',
        'payload': {
          'candidate': {
            'candidate': 'candidate:1',
            'sdpMid': '0',
            'sdpMLineIndex': 0
          }
        },
      });
      expect(ice?.type, CallSignalType.ice);
      expect(ice?.candidate?['candidate'], 'candidate:1');
      expect(ice?.candidate?['sdpMLineIndex'], 0);

      final hangup = parseCallSignal({
        'type': 'hangup',
        'from': 'caller-id',
        'to': 'callee-id',
        'callId': 'call-1',
        'callType': 'voice',
      });
      expect(hangup?.type, CallSignalType.hangup);
      expect(hangup?.payload, isEmpty);

      final decline = parseCallSignal({
        'type': 'decline',
        'from': 'callee-id',
        'to': 'caller-id',
        'callId': 'call-1',
        'callType': 'video',
      });
      expect(decline?.type, CallSignalType.decline);
    });

    test('parseCallSignal unwraps the Realtime broadcast envelope', () {
      final signal = parseCallSignal({
        'event': 'offer',
        'payload': offer,
      });
      expect(signal, isNotNull);
      expect(signal!.type, CallSignalType.offer);
      expect(signal.from, 'caller-id');
      expect(signal.sdp, 'v=0...');
    });

    test('parseCallSignal rejects unknown types', () {
      expect(
          parseCallSignal({
            'type': 'ring',
            'from': 'a',
            'to': 'b',
            'callId': 'c',
            'callType': 'voice',
          }),
          isNull);
      expect(parseCallSignal({'from': 'a', 'to': 'b', 'callId': 'c'}),
          isNull);
    });

    test('parseCallSignal rejects missing from/to/callId', () {
      expect(
          parseCallSignal({
            'type': 'offer',
            'to': 'b',
            'callId': 'c',
            'callType': 'voice',
          }),
          isNull);
      expect(
          parseCallSignal({
            'type': 'offer',
            'from': 'a',
            'callId': 'c',
            'callType': 'voice',
          }),
          isNull);
      expect(
          parseCallSignal({
            'type': 'offer',
            'from': 'a',
            'to': 'b',
            'callType': 'voice',
          }),
          isNull);
      expect(
          parseCallSignal({
            'type': 'offer',
            'from': '',
            'to': 'b',
            'callId': 'c',
            'callType': 'voice',
          }),
          isNull);
    });

    test('parseCallSignal rejects offer/answer without a valid callType',
        () {
      expect(
          parseCallSignal({
            'type': 'offer',
            'from': 'a',
            'to': 'b',
            'callId': 'c',
            'callType': 'smoke-signal',
          }),
          isNull);
      expect(
          parseCallSignal({
            'type': 'offer',
            'from': 'a',
            'to': 'b',
            'callId': 'c',
          }),
          isNull);
    });

    test('encodeCallSignal round-trips through parseCallSignal', () {
      final original = parseCallSignal(offer)!;
      final reparsed = parseCallSignal(encodeCallSignal(original));
      expect(reparsed, isNotNull);
      expect(reparsed!.type, original.type);
      expect(reparsed.from, original.from);
      expect(reparsed.to, original.to);
      expect(reparsed.callId, original.callId);
      expect(reparsed.callType, original.callType);
      expect(reparsed.sdp, original.sdp);
    });

    test('canCall is true only for direct chats', () {
      expect(canCall('direct'), isTrue);
      expect(canCall('group'), isFalse);
      expect(canCall('channel'), isFalse);
      expect(canCall(null), isFalse);
      expect(canCall('unknown'), isFalse);
    });

    test('callStatusLabel returns non-empty Arabic for every status', () {
      for (final status in [
        'ringing',
        'ongoing',
        'completed',
        'missed',
        'declined',
        'cancelled',
        'something-else',
        null,
      ]) {
        final label = callStatusLabel(status);
        expect(label, isNotEmpty);
        expect(label, isNot('ringing'));
        expect(label, isNot('ongoing'));
      }
      expect(callStatusLabel('ringing'), 'يرن…');
      expect(callStatusLabel('ongoing'), 'جارية');
      expect(callStatusLabel('completed'), 'مكتملة');
      expect(callStatusLabel('missed'), 'فائتة');
      expect(callStatusLabel('declined'), 'مرفوضة');
      expect(callStatusLabel('cancelled'), 'ملغاة');
    });

    test('formatCallDuration renders mm:ss', () {
      expect(formatCallDuration(Duration.zero), '00:00');
      expect(formatCallDuration(const Duration(seconds: 65)), '01:05');
      expect(
          formatCallDuration(const Duration(minutes: 12, seconds: 3)),
          '12:03');
    });
  });

  group('e2e helpers', () {
    Future<SimpleKeyPair> newPair() => X25519().newKeyPair();
    Future<String> pubOf(SimpleKeyPair pair) async =>
        base64Encode((await pair.extractPublicKey()).bytes);
    Future<List<int>> privOf(SimpleKeyPair pair) =>
        pair.extractPrivateKeyBytes();

    test('encrypt/decrypt round-trip with a random key', () async {
      final key = generateConversationKey();
      expect(key, hasLength(32));
      final enc = await encryptText('مرحباً بالعالم 👋', key);
      expect(enc.ciphertext, isNotEmpty);
      expect(enc.nonce, isNotEmpty);
      // Stored format: ciphertext = base64(cipherText || 16-byte tag),
      // nonce = base64(12 random bytes).
      expect(base64Decode(enc.nonce), hasLength(12));
      expect(await decryptText(enc.ciphertext, enc.nonce, key),
          'مرحباً بالعالم 👋');
    });

    test('encrypting twice gives different ciphertext and nonce', () async {
      final key = generateConversationKey();
      final first = await encryptText('same text', key);
      final second = await encryptText('same text', key);
      expect(first.ciphertext, isNot(second.ciphertext));
      expect(first.nonce, isNot(second.nonce));
    });

    test('decrypt with a different key fails', () async {
      final enc = await encryptText('secret', generateConversationKey());
      await expectLater(
        decryptText(enc.ciphertext, enc.nonce, generateConversationKey()),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('wrong nonce fails', () async {
      final key = generateConversationKey();
      final enc = await encryptText('secret', key);
      final wrongNonce = base64Encode(List<int>.filled(12, 0));
      await expectLater(
        decryptText(enc.ciphertext, wrongNonce, key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('tampered ciphertext fails', () async {
      final key = generateConversationKey();
      final enc = await encryptText('secret', key);
      final bytes = base64Decode(enc.ciphertext);
      bytes[0] ^= 0xFF;
      await expectLater(
        decryptText(base64Encode(bytes), enc.nonce, key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('X25519 shared-secret symmetry', () async {
      final alice = await newPair();
      final bob = await newPair();
      final aliceSecret = await deriveSharedSecret(
          await privOf(alice), await pubOf(bob));
      final bobSecret = await deriveSharedSecret(
          await privOf(bob), await pubOf(alice));
      expect(aliceSecret, hasLength(32));
      expect(aliceSecret, bobSecret);
    });

    test('wrap/unwrap round-trip', () async {
      final alice = await newPair();
      final bob = await newPair();
      final convKey = generateConversationKey();
      final wrapped = await wrapConversationKey(
          convKey, await privOf(alice), await pubOf(bob));
      final unwrapped = await unwrapConversationKey(
          wrapped, await privOf(bob), await pubOf(alice));
      expect(unwrapped, convKey);
    });

    test('wrap for the wrong recipient fails', () async {
      final alice = await newPair();
      final bob = await newPair();
      final carol = await newPair();
      final wrapped = await wrapConversationKey(
          generateConversationKey(), await privOf(alice), await pubOf(bob));
      // Carol tries to unwrap a key wrapped for Bob, using Alice's
      // public key: the shared secret differs, so authentication fails.
      await expectLater(
        unwrapConversationKey(
            wrapped, await privOf(carol), await pubOf(alice)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('isEncryptedMessage / canEncryptFor matrix', () {
      expect(isEncryptedMessage({'is_encrypted': true}), isTrue);
      expect(
          isEncryptedMessage(
              {'is_encrypted': false, 'ciphertext': 'abc123'}),
          isTrue);
      expect(
          isEncryptedMessage(
              {'is_encrypted': false, 'body': 'plain text'}),
          isFalse);
      expect(isEncryptedMessage({}), isFalse);
      expect(isEncryptedMessage({'ciphertext': ''}), isFalse);

      // canEncryptFor now requires real 32-byte base64 X25519 keys: the
      // two constants below are 32 zero bytes and bytes 0..31. Each
      // member maps to their device keys (deviceId null = legacy entry).
      expect(
          canEncryptFor({
            'a': [
              (
                deviceId: 'd1',
                publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
              ),
            ],
            'b': [
              (
                deviceId: 'd2',
                publicKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='
              ),
            ],
          }),
          isTrue);
      expect(
          canEncryptFor({
            'a': [
              (
                deviceId: 'd1',
                publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
              ),
            ],
            'b': <DeviceKey>[],
          }),
          isFalse);
      expect(
          canEncryptFor({
            'a': [
              (
                deviceId: 'd1',
                publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
              ),
            ],
            'b': [(deviceId: null, publicKey: '')],
          }),
          isFalse);
      expect(
          canEncryptFor({
            'a': [
              (
                deviceId: 'd1',
                publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
              ),
            ],
            'b': [(deviceId: null, publicKey: '   ')],
          }),
          isFalse);
      expect(canEncryptFor({}), isFalse);
    });
  });

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

    test('isJsonResponseBody distinguishes JSON from HTML pages', () {
      expect(isJsonResponseBody('{"code":400,"msg":"x"}'), isTrue);
      expect(isJsonResponseBody('  { "ok": true }'), isTrue);
      expect(
          isJsonResponseBody('<html><body>blocked</body></html>'), isFalse);
      expect(isJsonResponseBody(''), isFalse);
    });
  });
}
