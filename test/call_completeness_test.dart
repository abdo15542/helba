// Tests for the call-completeness build (ringtone, call push, history).
//
// Only pure-Dart helpers are tested here: call-history row mapping +
// duration + relative time, the call-push payload codec, the
// call-push body builder, the ringtone start/stop logic (via injected
// fakes — no platform channel), the requestOffer signal parse, and the
// call-status transition rules (mirroring migration 017's trigger).
// Anything needing Supabase, Firebase or a real device (actual
// ringtone sound, FCM delivery, the Edge Function, the history page
// query, the offer re-request round-trip) is NOT unit-testable here
// and must be verified on device / against the live project.

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/call_history.dart';
import 'package:helba/src/calls.dart';
import 'package:helba/src/push.dart';

const _me = '11111111-1111-1111-1111-111111111111';
const _other = '22222222-2222-2222-2222-222222222222';
const _callId = '33333333-3333-3333-3333-333333333333';

void main() {
  group('parseCallHistoryRow', () {
    test('outgoing call maps direction, name, type and times', () {
      final entry = parseCallHistoryRow(
        {
          'id': _callId,
          'caller_id': _me,
          'callee_id': _other,
          'type': 'video',
          'status': 'completed',
          'started_at': '2026-11-06T10:00:00.000Z',
          'ended_at': '2026-11-06T10:03:30.000Z',
        },
        _me,
        {_other: 'أحمد'},
      );
      expect(entry, isNotNull);
      expect(entry!.id, _callId);
      expect(entry.isOutgoing, isTrue);
      expect(entry.otherUserId, _other);
      expect(entry.otherName, 'أحمد');
      expect(entry.callType, 'video');
      expect(entry.status, 'completed');
      expect(entry.isMissed, isFalse);
      expect(entry.duration, const Duration(minutes: 3, seconds: 30));
    });

    test('incoming missed call flags isMissed, no duration', () {
      final entry = parseCallHistoryRow(
        {
          'id': _callId,
          'caller_id': _other,
          'callee_id': _me,
          'type': 'voice',
          'status': 'missed',
          'started_at': '2026-11-06T10:00:00.000Z',
          'ended_at': '2026-11-06T10:01:00.000Z',
        },
        _me,
        {_other: 'سارة'},
      );
      expect(entry, isNotNull);
      expect(entry!.isOutgoing, isFalse);
      expect(entry.isMissed, isTrue);
      expect(entry.duration, isNull);
    });

    test('missing name falls back to مستخدم', () {
      final entry = parseCallHistoryRow(
        {
          'id': _callId,
          'caller_id': _other,
          'callee_id': _me,
          'type': 'voice',
          'status': 'declined',
          'started_at': '2026-11-06T10:00:00.000Z',
          'ended_at': null,
        },
        _me,
        {},
      );
      expect(entry, isNotNull);
      expect(entry!.otherName, 'مستخدم');
      expect(entry.duration, isNull);
    });

    test('unknown type normalises to voice', () {
      final entry = parseCallHistoryRow(
        {
          'id': _callId,
          'caller_id': _me,
          'callee_id': _other,
          'type': 'hologram',
          'status': 'completed',
          'started_at': '2026-11-06T10:00:00.000Z',
          'ended_at': '2026-11-06T10:00:10.000Z',
        },
        _me,
        {_other: 'أحمد'},
      );
      expect(entry, isNotNull);
      expect(entry!.callType, 'voice');
    });

    test('unusable rows return null', () {
      expect(parseCallHistoryRow({}, _me, {}), isNull);
      // Row that involves neither me nor the other party.
      expect(
        parseCallHistoryRow(
          {
            'id': _callId,
            'caller_id': '44444444-4444-4444-4444-444444444444',
            'callee_id': '55555555-5555-5555-5555-555555555555',
            'type': 'voice',
            'status': 'completed',
            'started_at': '2026-11-06T10:00:00.000Z',
            'ended_at': '2026-11-06T10:00:10.000Z',
          },
          _me,
          {},
        ),
        isNull,
      );
      // Ended before started: no duration.
      final entry = parseCallHistoryRow(
        {
          'id': _callId,
          'caller_id': _me,
          'callee_id': _other,
          'type': 'voice',
          'status': 'completed',
          'started_at': '2026-11-06T10:00:10.000Z',
          'ended_at': '2026-11-06T10:00:00.000Z',
        },
        _me,
        {_other: 'أحمد'},
      );
      expect(entry, isNotNull);
      expect(entry!.duration, isNull);
    });
  });

  group('formatCallHistoryTime', () {
    final now = DateTime(2026, 11, 6, 14, 30);
    test('today', () {
      expect(
        formatCallHistoryTime(DateTime(2026, 11, 6, 9, 5), now: now),
        'اليوم 09:05',
      );
    });
    test('yesterday', () {
      expect(
        formatCallHistoryTime(DateTime(2026, 11, 5, 23, 59), now: now),
        'أمس 23:59',
      );
    });
    test('older', () {
      expect(
        formatCallHistoryTime(DateTime(2026, 10, 20, 8, 0), now: now),
        '20/10/2026 08:00',
      );
    });
  });

  group('call push payload codec', () {
    test('parses a valid call payload', () {
      final payload = parseCallPushData({
        'type': 'call',
        'call_id': _callId,
        'caller_id': _other,
        'caller_name': ' أحمد ',
        'call_type': 'video',
      });
      expect(payload, isNotNull);
      expect(payload!.callId, _callId);
      expect(payload.callerId, _other);
      expect(payload.callerName, 'أحمد');
      expect(payload.callType, 'video');
    });

    test('rejects non-call, missing and malformed payloads', () {
      expect(parseCallPushData({'type': 'message'}), isNull);
      expect(parseCallPushData({'type': 'call'}), isNull);
      expect(
        parseCallPushData({
          'type': 'call',
          'call_id': 'not-a-uuid',
          'caller_id': _other,
        }),
        isNull,
      );
      expect(
        parseCallPushData({
          'type': 'call',
          'call_id': _callId,
          'caller_id': 'not-a-uuid',
        }),
        isNull,
      );
      // Unknown call type normalises to voice, empty name drops out.
      final payload = parseCallPushData({
        'type': 'call',
        'call_id': _callId,
        'caller_id': _other,
        'caller_name': '   ',
        'call_type': 'hologram',
      });
      expect(payload, isNotNull);
      expect(payload!.callType, 'voice');
      expect(payload.callerName, isNull);
    });

    test('encode/decode round-trips, and rejects chat payloads', () {
      const payload = CallPushPayload(
        callId: _callId,
        callerId: _other,
        callerName: 'أحمد|المتصل',
        callType: 'video',
      );
      final encoded = encodeCallPushPayload(payload);
      final decoded = decodeCallPushPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.callId, _callId);
      expect(decoded.callerName, 'أحمد|المتصل');
      expect(decoded.callType, 'video');
      // A chat notification payload is a bare conversation id, not JSON.
      expect(decodeCallPushPayload(_callId), isNull);
      expect(decodeCallPushPayload(''), isNull);
      expect(decodeCallPushPayload(null), isNull);
      expect(decodeCallPushPayload('{not json'), isNull);
    });
  });

  group('buildCallPushBody', () {
    test('builds the exact body send-call-push expects', () {
      expect(
        buildCallPushBody(
          callId: _callId,
          calleeId: _other,
          callerId: _me,
          callType: 'video',
        ),
        {
          'call_id': _callId,
          'callee_id': _other,
          'caller_id': _me,
          'call_type': 'video',
        },
      );
    });
  });

  group('parseCallPushResult + callPushWarningMessage (fixes 7/8)', () {
    test('sent > 0 means the callee was reached, no warning', () {
      final result = parseCallPushResult({
        'ok': true,
        'sent': 1,
        'failed': 0,
        'details': [
          {'fid': 'abc…', 'ok': true, 'status': 200, 'error': null},
        ],
      });
      expect(result.ok, isTrue);
      expect(result.sent, 1);
      expect(result.failed, 0);
      expect(result.reachedCallee, isTrue);
      expect(result.nothingSent, isFalse);
      expect(callPushWarningMessage(result), isNull);
    });

    test('sent 0 with no_tokens warns that the other phone is unregistered',
        () {
      final result = parseCallPushResult({
        'ok': true,
        'sent': 0,
        'failed': 0,
        'reason': 'no_tokens',
        'details': [],
      });
      expect(result.ok, isTrue);
      expect(result.reachedCallee, isFalse);
      expect(result.nothingSent, isTrue);
      expect(result.reason, 'no_tokens');
      final warning = callPushWarningMessage(result);
      expect(warning, isNotNull);
      expect(warning, contains('غير مسجّل'));
    });

    test('sent 0 with all_failed warns that the push did not arrive', () {
      final result = parseCallPushResult({
        'ok': true,
        'sent': 0,
        'failed': 2,
        'reason': 'all_failed',
        'details': [
          {'fid': 'abc…', 'ok': false, 'status': 404, 'error': 'unregistered'},
          {'fid': 'def…', 'ok': false, 'status': 500, 'error': 'fcm_500'},
        ],
      });
      expect(result.nothingSent, isTrue);
      expect(callPushWarningMessage(result), contains('لم يصل'));
    });

    test('call_not_ringing needs no warning (the call is already dead)',
        () {
      final result = parseCallPushResult({
        'ok': true,
        'sent': 0,
        'failed': 0,
        'reason': 'call_not_ringing',
      });
      expect(callPushWarningMessage(result), isNull);
    });

    test('a failed function call warns generically', () {
      final result = parseCallPushResult({
        'ok': false,
        'error': 'oauth failed',
      });
      expect(result.ok, isFalse);
      expect(result.reachedCallee, isFalse);
      expect(callPushWarningMessage(result), contains('تعذّر إرسال'));
    });

    test('a malformed response is a failed result, never a crash', () {
      for (final bad in [null, 'garbage', 42, [], {'ok': 'yes'}]) {
        final result = parseCallPushResult(bad);
        expect(result.ok, isFalse);
        expect(result.sent, 0);
        expect(result.reachedCallee, isFalse);
        expect(callPushWarningMessage(result), isNotNull);
      }
    });
  });

  group('CallRingtone', () {
    test('start plays once, second start is a no-op', () async {
      var playCalls = 0;
      var stopCalls = 0;
      final ringtone = CallRingtone(
        play: () async => playCalls++,
        stop: () async => stopCalls++,
      );
      await ringtone.start();
      expect(ringtone.playing, isTrue);
      await ringtone.start();
      expect(playCalls, 1);
      await ringtone.stop();
      expect(stopCalls, 1);
      expect(ringtone.playing, isFalse);
      // Stopping again is a no-op.
      await ringtone.stop();
      expect(stopCalls, 1);
    });

    test('play failure never throws and leaves playing false', () async {
      var stopCalls = 0;
      final ringtone = CallRingtone(
        play: () async => throw StateError('no ringtone player'),
        stop: () async => stopCalls++,
      );
      // Must not throw: the caller falls back to vibration instead.
      await ringtone.start();
      expect(ringtone.playing, isFalse);
      // Nothing to stop.
      await ringtone.stop();
      expect(stopCalls, 0);
    });

    test('stop failure still clears the playing flag', () async {
      final ringtone = CallRingtone(
        play: () async {},
        stop: () async => throw StateError('stop failed'),
      );
      await ringtone.start();
      expect(ringtone.playing, isTrue);
      await ringtone.stop();
      expect(ringtone.playing, isFalse);
    });
  });

  group('requestOffer signal', () {
    test('parses and round-trips through encodeCallSignal', () {
      final signal = parseCallSignal({
        'type': 'requestOffer',
        'from': _me,
        'to': _other,
        'callId': _callId,
        'callType': 'video',
      });
      expect(signal, isNotNull);
      expect(signal!.type, CallSignalType.requestOffer);
      expect(signal.callId, _callId);
      expect(signal.callType, 'video');
      final restored = parseCallSignal(encodeCallSignal(signal));
      expect(restored, isNotNull);
      expect(restored!.type, CallSignalType.requestOffer);
      expect(restored.callId, _callId);
      expect(restored.callType, 'video');
    });

    test('unknown signal types return null', () {
      expect(
        parseCallSignal({
          'type': 'teleport',
          'from': _me,
          'to': _other,
          'callId': _callId,
          'callType': 'voice',
        }),
        isNull,
      );
    });
  });

  group('call status transitions (migration 017)', () {
    test('terminal statuses', () {
      expect(isTerminalCallStatus('completed'), isTrue);
      expect(isTerminalCallStatus('missed'), isTrue);
      expect(isTerminalCallStatus('declined'), isTrue);
      expect(isTerminalCallStatus('cancelled'), isTrue);
      expect(isTerminalCallStatus('ringing'), isFalse);
      expect(isTerminalCallStatus('ongoing'), isFalse);
    });

    test('valid transitions', () {
      expect(isValidCallTransition('ringing', 'ongoing'), isTrue);
      expect(isValidCallTransition('ringing', 'missed'), isTrue);
      expect(isValidCallTransition('ringing', 'declined'), isTrue);
      expect(isValidCallTransition('ringing', 'cancelled'), isTrue);
      expect(isValidCallTransition('ongoing', 'completed'), isTrue);
      // Same-status is allowed (idempotent retry).
      expect(isValidCallTransition('ringing', 'ringing'), isTrue);
      expect(isValidCallTransition('completed', 'completed'), isTrue);
    });

    test('invalid transitions', () {
      expect(isValidCallTransition('ongoing', 'missed'), isFalse);
      expect(isValidCallTransition('ongoing', 'declined'), isFalse);
      expect(isValidCallTransition('completed', 'missed'), isFalse);
      expect(isValidCallTransition('missed', 'completed'), isFalse);
      expect(isValidCallTransition('declined', 'ongoing'), isFalse);
      expect(isValidCallTransition('ringing', 'completed'), isFalse);
    });
  });
}
