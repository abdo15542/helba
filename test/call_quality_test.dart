// Tests for the WhatsApp-parity call quality/reliability build:
// video capture constraints (720p @ 30fps), the 2.5 Mbps sender cap,
// the bounded ICE-restart decision, and the mid-call renegotiation
// (re-offer) detection. Only pure-Dart helpers are tested here —
// anything needing a live peer connection, a real camera, or a device
// (the actual bitrate cap, the restart round-trip, the reconnecting
// label) must be verified on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:helba/src/calls.dart';

const _callId = '33333333-3333-3333-3333-333333333333';
const _otherCallId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('callVideoConstraints', () {
    test('requests 720p at 30fps, front camera', () {
      final c = callVideoConstraints();
      expect(c['facingMode'], 'user');
      expect(c['width'], {'ideal': 1280});
      expect(c['height'], {'ideal': 720});
      expect(c['frameRate'], {'ideal': 30});
    });

    test('matches the video quality constants', () {
      expect(callVideoWidth, 1280);
      expect(callVideoHeight, 720);
      expect(callVideoFrameRate, 30);
    });
  });

  group('callVideoMaxBitrate', () {
    test('caps the video sender at 2.5 Mbps', () {
      expect(callVideoMaxBitrate, 2500000);
    });
  });

  group('shouldAttemptIceRestart', () {
    test('attempts when the call is active and no restart was tried', () {
      expect(
          shouldAttemptIceRestart(attempted: false, isActiveCall: true),
          isTrue);
    });

    test('never attempts a second restart for the same call', () {
      expect(
          shouldAttemptIceRestart(attempted: true, isActiveCall: true),
          isFalse);
    });

    test('never attempts when the call is not active', () {
      expect(
          shouldAttemptIceRestart(attempted: false, isActiveCall: false),
          isFalse);
    });

    test('never attempts when already tried and the call is not active',
        () {
      expect(
          shouldAttemptIceRestart(attempted: true, isActiveCall: false),
          isFalse);
    });
  });

  group('iceRestartOfferConstraints', () {
    test('requests an ICE restart in the re-offer', () {
      expect(iceRestartOfferConstraints, {'iceRestart': true});
    });
  });

  group('disconnectReconnectDelay', () {
    test('gives a brief drop 10s to recover before restarting ICE', () {
      expect(disconnectReconnectDelay, const Duration(seconds: 10));
    });
  });

  // (No static turnIceServers list any more: TURN servers are fetched
  // per call from the `turn-credentials` Edge Function — see
  // parseTurnIceServers in turn_credentials_test.dart. An empty fetch
  // result is the STUN-only fallback.)

  group('isRenegotiationOffer', () {
    test('active call, same callId, SDP present -> renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.active,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isTrue);
    });

    test('outgoing call, same callId, SDP present -> renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.outgoing,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isTrue);
    });

    test('idle state is never a renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.idle,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isFalse);
    });

    test('incoming state is never a renegotiation (it is a new call)', () {
      expect(
          isRenegotiationOffer(
              state: CallState.incoming,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isFalse);
    });

    test('a different callId is never a renegotiation (busy decline)',
        () {
      expect(
          isRenegotiationOffer(
              state: CallState.active,
              signalCallId: _otherCallId,
              currentCallId: _callId,
              sdp: 'v=0\r\n...'),
          isFalse);
    });

    test('an offer without SDP is never a renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.active,
              signalCallId: _callId,
              currentCallId: _callId,
              sdp: null),
          isFalse);
    });

    test('no current call is never a renegotiation', () {
      expect(
          isRenegotiationOffer(
              state: CallState.active,
              signalCallId: _callId,
              currentCallId: null,
              sdp: 'v=0\r\n...'),
          isFalse);
    });
  });
}
