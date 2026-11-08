// Tests for the call fixes in build 156:
//  (1) truthful "connected" state — the call only becomes `active` once
//      media really flows (Connected + remote stream), so the timer
//      never runs over silence; TURN ICE servers are cached for 24h
//      instead of a serial fetch per call; the DB signalling poll runs
//      every 1s while connecting and backs off to 3s once connected.
//  (2) closed-app calls ring — the background message handler shows a
//      full-screen incoming-call notification (Answer / Decline) on the
//      helba_calls channel, whose sound is the bundled ringtone.
// Only pure-Dart helpers are tested here — the background isolate, the
// actual ringtone playback and the full-screen intent must be verified
// on device.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:helba/src/calls.dart';
import 'package:helba/src/push.dart';

const _callId = '33333333-3333-3333-3333-333333333333';
const _callerId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('isMediaReady', () {
    test('Connected + remote stream -> media is ready', () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateConnected,
              hasRemoteStream: true),
          isTrue);
    });

    test('Connected but no remote stream -> not ready (no audio yet)',
        () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateConnected,
              hasRemoteStream: false),
          isFalse);
    });

    test('remote stream but only connecting -> not ready', () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
              hasRemoteStream: true),
          isFalse);
    });

    test('disconnected + remote stream -> not ready', () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
              hasRemoteStream: true),
          isFalse);
    });

    test('failed + remote stream -> not ready', () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateFailed,
              hasRemoteStream: true),
          isFalse);
    });

    test('new + no remote stream -> not ready', () {
      expect(
          isMediaReady(
              connectionState:
                  RTCPeerConnectionState.RTCPeerConnectionStateNew,
              hasRemoteStream: false),
          isFalse);
    });
  });

  group('TURN cache validity (isTurnCacheValid / shouldRefreshTurnCache)',
      () {
    test('a null fetch time is never valid and never refreshes', () {
      final now = DateTime(2026, 11, 8, 12);
      expect(isTurnCacheValid(fetchedAt: null, now: now), isFalse);
      expect(shouldRefreshTurnCache(fetchedAt: null, now: now), isFalse);
    });

    test('freshly fetched servers are valid and need no refresh', () {
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt: now.subtract(const Duration(minutes: 5)),
              now: now),
          isTrue);
      expect(
          shouldRefreshTurnCache(
              fetchedAt: now.subtract(const Duration(minutes: 5)),
              now: now),
          isFalse);
    });

    test('servers fetched 12h ago are valid and need no refresh', () {
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt: now.subtract(const Duration(hours: 12)),
              now: now),
          isTrue);
      expect(
          shouldRefreshTurnCache(
              fetchedAt: now.subtract(const Duration(hours: 12)),
              now: now),
          isFalse);
    });

    test('servers fetched 23h ago are valid but do not refresh yet', () {
      // Exactly 1h remains — not LESS than 1h — so no refresh yet.
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt: now.subtract(const Duration(hours: 23)),
              now: now),
          isTrue);
      expect(
          shouldRefreshTurnCache(
              fetchedAt: now.subtract(const Duration(hours: 23)),
              now: now),
          isFalse);
    });

    test('servers fetched 23h01m ago are valid and refresh in background',
        () {
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt:
                  now.subtract(const Duration(hours: 23, minutes: 1)),
              now: now),
          isTrue);
      expect(
          shouldRefreshTurnCache(
              fetchedAt:
                  now.subtract(const Duration(hours: 23, minutes: 1)),
              now: now),
          isTrue);
    });

    test('servers fetched 23h30m ago are valid but refresh in background',
        () {
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt: now.subtract(const Duration(hours: 23, minutes: 30)),
              now: now),
          isTrue);
      expect(
          shouldRefreshTurnCache(
              fetchedAt: now.subtract(const Duration(hours: 23, minutes: 30)),
              now: now),
          isTrue);
    });

    test('servers fetched 25h ago are stale and never refresh', () {
      final now = DateTime(2026, 11, 8, 12);
      expect(
          isTurnCacheValid(
              fetchedAt: now.subtract(const Duration(hours: 25)),
              now: now),
          isFalse);
      expect(
          shouldRefreshTurnCache(
              fetchedAt: now.subtract(const Duration(hours: 25)),
              now: now),
          isFalse);
    });

    test('the TTL is 24h and the refresh threshold is 1h', () {
      expect(turnCacheTtl, const Duration(hours: 24));
      expect(turnCacheRefreshThreshold, const Duration(hours: 1));
    });
  });

  group('dbPollInterval', () {
    test('polls every 1s while the connection is still establishing',
        () {
      expect(dbPollInterval(connected: false),
          const Duration(seconds: 1));
      expect(dbPollIntervalConnecting, const Duration(seconds: 1));
    });

    test('backs off to 3s once connected', () {
      expect(dbPollInterval(connected: true), const Duration(seconds: 3));
      expect(dbPollIntervalConnected, const Duration(seconds: 3));
    });
  });

  group('isRenegotiationOffer while connecting', () {
    test('connecting call, same callId, SDP present -> renegotiation',
        () {
      expect(
          isRenegotiationOffer(
              state: CallState.connecting,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isTrue);
    });

    test('connecting call, different callId -> not a renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.connecting,
              signalCallId: '55555555-5555-5555-5555-555555555555',
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isFalse);
    });

    test('connecting call, no SDP -> not a renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.connecting,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: null),
          isFalse);
    });
  });

  group('background-handler call detection (parseCallPushData)', () {
    test('the exact send-call-push data shape is a call', () {
      final payload = parseCallPushData({
        'type': 'call',
        'call_id': _callId,
        'caller_id': _callerId,
        'caller_name': 'عبد الحميد',
        'call_type': 'voice',
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
      });
      expect(payload, isNotNull);
      expect(payload!.callId, _callId);
      expect(payload.callerId, _callerId);
      expect(payload.callerName, 'عبد الحميد');
      expect(payload.callType, 'voice');
    });

    test('a video call push is a call with type video', () {
      final payload = parseCallPushData({
        'type': 'call',
        'call_id': _callId,
        'caller_id': _callerId,
        'call_type': 'video',
      });
      expect(payload, isNotNull);
      expect(payload!.callType, 'video');
    });

    test('a normal message push is not a call (ignored in background)',
        () {
      expect(
          parseCallPushData({
            'type': 'message',
            'conversation_id': _callId,
            'sender_id': _callerId,
            'body': 'مرحبا',
          }),
          isNull);
    });

    test('an app-update push is not a call (ignored in background)', () {
      expect(
          parseCallPushData({'type': 'app_update', 'build': '156'}),
          isNull);
    });

    test('a call push with a malformed call id is not a call', () {
      expect(
          parseCallPushData({
            'type': 'call',
            'call_id': 'not-a-uuid',
            'caller_id': _callerId,
          }),
          isNull);
    });
  });

  group('incomingCallNotificationDetails', () {
    test('full-screen incoming-call notification on helba_calls', () {
      final details = incomingCallNotificationDetails();
      expect(details.channelId, pushCallsChannelId);
      expect(details.importance, Importance.max);
      expect(details.priority, Priority.max);
      expect(details.category, AndroidNotificationCategory.call);
      expect(details.fullScreenIntent, isTrue);
      expect(details.ongoing, isTrue);
      expect(details.autoCancel, isFalse);
      expect(details.playSound, isTrue);
      expect(details.enableVibration, isTrue);
    });

    test('has Answer and Decline actions that open the app', () {
      final details = incomingCallNotificationDetails();
      final actions = details.actions ?? const [];
      expect(actions.length, 2);
      final answer =
          actions.firstWhere((a) => a.id == callNotificationActionAnswer);
      expect(answer.title, 'رد');
      expect(answer.showsUserInterface, isTrue);
      final decline =
          actions.firstWhere((a) => a.id == callNotificationActionDecline);
      expect(decline.title, 'رفض');
      expect(decline.showsUserInterface, isTrue);
      expect(decline.cancelNotification, isTrue);
    });
  });

  group('helbaCallsChannel', () {
    test('uses the bundled ringtone as its sound', () {
      expect(helbaCallsChannel.id, pushCallsChannelId);
      expect(helbaCallsChannel.importance, Importance.max);
      expect(helbaCallsChannel.playSound, isTrue);
      expect(helbaCallsChannel.enableVibration, isTrue);
      final sound = helbaCallsChannel.sound;
      expect(sound, isA<RawResourceAndroidNotificationSound>());
      expect(
          (sound as RawResourceAndroidNotificationSound).sound,
          'helba_ringtone');
    });
  });

  group('CallRingtone.stopAny', () {
    test('stops the platform ringtone even when never started here',
        () async {
      var stopCalls = 0;
      final ringtone = CallRingtone(
        play: () async {},
        stop: () async => stopCalls++,
      );
      // This instance never started: the background handler did, in
      // another isolate. stopAny must still call the platform stop.
      await ringtone.stopAny();
      expect(stopCalls, 1);
      expect(ringtone.playing, isFalse);
    });

    test('stopAny after start stops once and clears playing', () async {
      var stopCalls = 0;
      final ringtone = CallRingtone(
        play: () async {},
        stop: () async => stopCalls++,
      );
      await ringtone.start();
      expect(ringtone.playing, isTrue);
      await ringtone.stopAny();
      expect(stopCalls, 1);
      expect(ringtone.playing, isFalse);
    });

    test('stopAny never throws when the platform stop fails', () async {
      final ringtone = CallRingtone(
        play: () async {},
        stop: () async => throw StateError('stop failed'),
      );
      await ringtone.stopAny();
      expect(ringtone.playing, isFalse);
    });
  });
}
