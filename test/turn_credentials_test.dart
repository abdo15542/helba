// Tests for the Cloudflare TURN plumbing: the app fetches short-lived
// relay servers from the `turn-credentials` Edge Function at call start
// and merges them into the peer connection after STUN. Only the pure
// response parser is tested here — the actual function invocation (and
// whether the secrets are set) needs a live Supabase backend.
import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/calls.dart';

void main() {
  group('parseTurnIceServers', () {
    test('valid Cloudflare-style response with a urls list', () {
      final servers = parseTurnIceServers({
        'iceServers': [
          {
            'urls': [
              'turn:turn.cloudflare.com:3478?transport=udp',
              'turn:turn.cloudflare.com:3478?transport=tcp',
              'turns:turn.cloudflare.com:5349?transport=tcp',
            ],
            'username': 'user123',
            'credential': 'secret456',
          },
        ],
      });
      expect(servers, hasLength(1));
      expect(
        servers.first['urls'],
        [
          'turn:turn.cloudflare.com:3478?transport=udp',
          'turn:turn.cloudflare.com:3478?transport=tcp',
          'turns:turn.cloudflare.com:5349?transport=tcp',
        ],
      );
      expect(servers.first['username'], 'user123');
      expect(servers.first['credential'], 'secret456');
    });

    test('single-string urls are kept as a string', () {
      final servers = parseTurnIceServers({
        'iceServers': [
          {
            'urls': 'turn:turn.example.com:3478',
            'username': 'u',
            'credential': 'c',
          },
        ],
      });
      expect(servers, hasLength(1));
      expect(servers.first['urls'], 'turn:turn.example.com:3478');
      expect(servers.first['username'], 'u');
      expect(servers.first['credential'], 'c');
    });

    test('username/credential omitted when absent or blank', () {
      final servers = parseTurnIceServers({
        'iceServers': [
          {'urls': 'turn:turn.example.com:3478'},
          {
            'urls': 'turn:turn.example.com:3479',
            'username': '   ',
            'credential': '',
          },
        ],
      });
      expect(servers, hasLength(2));
      expect(servers.first.containsKey('username'), isFalse);
      expect(servers.first.containsKey('credential'), isFalse);
      expect(servers.last.containsKey('username'), isFalse);
      expect(servers.last.containsKey('credential'), isFalse);
    });

    test('non-map top level returns an empty list', () {
      expect(parseTurnIceServers(null), isEmpty);
      expect(parseTurnIceServers('nope'), isEmpty);
      expect(parseTurnIceServers([]), isEmpty);
      expect(parseTurnIceServers(42), isEmpty);
    });

    test('missing or non-list iceServers returns an empty list', () {
      expect(parseTurnIceServers({}), isEmpty);
      expect(parseTurnIceServers({'iceServers': null}), isEmpty);
      expect(parseTurnIceServers({'iceServers': 'turn:x'}), isEmpty);
      expect(parseTurnIceServers({'iceServers': {}}), isEmpty);
    });

    test('empty iceServers array returns an empty list', () {
      expect(parseTurnIceServers({'iceServers': []}), isEmpty);
    });

    test('malformed entries are skipped, valid ones kept', () {
      final servers = parseTurnIceServers({
        'iceServers': [
          null,
          'turn:turn.example.com:3478',
          42,
          {'username': 'u', 'credential': 'c'},
          {'urls': ''},
          {'urls': '   '},
          {'urls': []},
          {'urls': ['', '   ']},
          {'urls': 42},
          {
            'urls': ['turn:turn.example.com:3478', '', 7, '   '],
            'username': 'u',
            'credential': 'c',
          },
        ],
      });
      expect(servers, hasLength(1));
      expect(servers.first['urls'], 'turn:turn.example.com:3478');
      expect(servers.first['username'], 'u');
      expect(servers.first['credential'], 'c');
    });

    test('multiple valid entries are all returned in order', () {
      final servers = parseTurnIceServers({
        'iceServers': [
          {'urls': 'stun:stun.example.com:3478'},
          {
            'urls': ['turn:a.example.com:3478', 'turn:b.example.com:3478'],
            'username': 'u1',
            'credential': 'c1',
          },
        ],
      });
      expect(servers, hasLength(2));
      expect(servers[0]['urls'], 'stun:stun.example.com:3478');
      expect(
        servers[1]['urls'],
        ['turn:a.example.com:3478', 'turn:b.example.com:3478'],
      );
    });
  });
}
