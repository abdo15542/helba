import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Voice/video calls: WebRTC peer-to-peer with Supabase Realtime broadcast
// signalling on personal channels `call:user:<id>`.
//
// HONEST LIMIT: STUN only (stun.l.google.com:19302), NO TURN server and no
// media server. Calls work on most home/mobile networks but may fail on
// strict symmetric-NAT or corporate networks that need a TURN relay.
// The call screen says so in Arabic. Same limit as the sibling Lamma app.
// ---------------------------------------------------------------------------

/// How long an unanswered call rings before it is marked missed.
const callRingTimeout = Duration(seconds: 30);

/// The navigator key the app's MaterialApp uses, so an incoming call can
/// be shown from anywhere (inbox or inside a chat) without a BuildContext.
final GlobalKey<NavigatorState> helbaNavigatorKey =
    GlobalKey<NavigatorState>();

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// Signalling message kinds. `offer`/`answer` carry SDP, `ice` carries one
/// ICE candidate, `hangup`/`decline` carry no payload.
enum CallSignalType { offer, answer, ice, hangup, decline }

CallSignalType? _signalTypeFromString(String? value) {
  switch (value) {
    case 'offer':
      return CallSignalType.offer;
    case 'answer':
      return CallSignalType.answer;
    case 'ice':
      return CallSignalType.ice;
    case 'hangup':
      return CallSignalType.hangup;
    case 'decline':
      return CallSignalType.decline;
    default:
      return null;
  }
}

/// One signalling message. [payload] holds `{'sdp': ..., 'type': ...}` for
/// offer/answer and `{'candidate': {...}}` for ice; it is empty otherwise.
class CallSignal {
  final CallSignalType type;
  final String from;
  final String to;
  final String callId;
  final String callType;
  final Map<String, dynamic> payload;

  const CallSignal({
    required this.type,
    required this.from,
    required this.to,
    required this.callId,
    required this.callType,
    this.payload = const {},
  });

  /// SDP string for offer/answer signals, null otherwise.
  String? get sdp => payload['sdp']?.toString();

  /// SDP type ('offer'/'answer') for offer/answer signals, null otherwise.
  String? get sdpType => payload['type']?.toString();

  /// ICE candidate map for ice signals, null otherwise.
  Map<String, dynamic>? get candidate {
    final value = payload['candidate'];
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}

/// Parses a signalling message. Accepts both the bare signal map and the
/// Realtime broadcast envelope `{'event': ..., 'payload': {...}}` that
/// `onBroadcast` delivers (the envelope is unwrapped when the outer map
/// has no `from` field).
///
/// Returns null (rather than throwing) on an unknown type or a missing
/// required field (`from`/`to`/`callId`, and `callType` for offer/answer),
/// so one malformed broadcast can never crash the call listener.
CallSignal? parseCallSignal(Map<String, dynamic> raw) {
  var map = raw;
  if (map['payload'] is Map && !map.containsKey('from')) {
    map = Map<String, dynamic>.from(map['payload'] as Map);
  }
  final type = _signalTypeFromString(
      map['type']?.toString() ?? raw['event']?.toString());
  if (type == null) return null;
  final from = map['from']?.toString() ?? '';
  final to = map['to']?.toString() ?? '';
  final callId = map['callId']?.toString() ?? '';
  if (from.isEmpty || to.isEmpty || callId.isEmpty) return null;
  final callType = map['callType']?.toString() ?? '';
  if ((type == CallSignalType.offer || type == CallSignalType.answer) &&
      callType != 'voice' &&
      callType != 'video') {
    return null;
  }
  final payload = map['payload'] is Map
      ? Map<String, dynamic>.from(map['payload'] as Map)
      : <String, dynamic>{};
  return CallSignal(
    type: type,
    from: from,
    to: to,
    callId: callId,
    callType: callType.isEmpty ? 'voice' : callType,
    payload: payload,
  );
}

/// Encodes a signal for `sendBroadcastMessage`. Round-trips through
/// [parseCallSignal]: every field survives.
Map<String, dynamic> encodeCallSignal(CallSignal signal) => {
      'type': signal.type.name,
      'from': signal.from,
      'to': signal.to,
      'callId': signal.callId,
      'callType': signal.callType,
      'payload': signal.payload,
    };

/// Arabic label for a call-history status. Unknown statuses fall back to
/// the generic label rather than showing a raw English value.
String callStatusLabel(String? status) {
  switch (status) {
    case 'ringing':
      return 'يرن…';
    case 'ongoing':
      return 'جارية';
    case 'completed':
      return 'مكتملة';
    case 'missed':
      return 'فائتة';
    case 'declined':
      return 'مرفوضة';
    case 'cancelled':
      return 'ملغاة';
    default:
      return 'مكالمة';
  }
}

/// Arabic label for a call type.
String callTypeLabel(String? callType) =>
    callType == 'video' ? 'مكالمة فيديو' : 'مكالمة صوتية';

/// Calls are peer-to-peer and 1:1, so only direct chats can start one.
/// Groups and channels have no single other participant.
bool canCall(String? kind) => kind == 'direct';

// ---------------------------------------------------------------------------
// Call state.
// ---------------------------------------------------------------------------

enum CallState { idle, outgoing, incoming, active, ended }

// ---------------------------------------------------------------------------
// Call service: owns the peer connection, the local/remote streams and the
// Realtime signalling subscription. Single instance, like the deep-link
// listener: the app starts it once the user is signed in (see auth.dart).
// ---------------------------------------------------------------------------

class CallService {
  static final CallService instance = CallService._();
  CallService._();

  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);

  /// The currently ringing incoming call, if any. The overlay observes
  /// this; when it becomes null the overlay dismisses itself.
  final ValueNotifier<CallSignal?> incomingCall = ValueNotifier(null);

  /// Display name of the incoming caller, loaded best-effort from profiles.
  final ValueNotifier<String?> incomingCallerName = ValueNotifier(null);

  final ValueNotifier<MediaStream?> localStream = ValueNotifier(null);
  final ValueNotifier<MediaStream?> remoteStream = ValueNotifier(null);
  final ValueNotifier<bool> isMuted = ValueNotifier(false);
  final ValueNotifier<bool> isCameraOff = ValueNotifier(false);
  final ValueNotifier<bool> isSpeakerOn = ValueNotifier(false);

  /// Why the last call ended ('declined', 'missed', 'ended'); read by the
  /// call screen before it pops. Null while a call is in progress.
  String? endReason;

  /// Last connection-failure message for the call screen to show
  /// ('تعذّر الاتصال'), e.g. when the peer connection fails after the
  /// call was answered. Null unless the call ended this way; cleared
  /// when the next call starts.
  final ValueNotifier<String?> callError = ValueNotifier(null);

  /// Offer queued when the incoming-call overlay could not be shown
  /// (no navigator context yet). Retried until the call is answered,
  /// declined or times out. See [_showIncomingOverlay].
  CallSignal? _pendingIncomingCall;
  Timer? _pendingOverlayTimer;

  String? currentCallId;
  String? currentPeerId;
  String? currentPeerName;
  String? currentCallType;
  String? currentCallRowId;

  bool get isVideoCall => currentCallType == 'video';

  RTCPeerConnection? _pc;
  MediaStream? _local;
  RealtimeChannel? _myChannel;
  final Map<String, RealtimeChannel> _peerChannels = {};
  String? _listeningUserId;
  Timer? _ringTimer;
  Timer? _connectionTimer;
  bool _answered = false;
  bool _rowFinalized = false;
  bool _overlayShowing = false;
  bool _starting = false;

  SupabaseClient get _client => Supabase.instance.client;

  // -- Signalling subscription ---------------------------------------------

  /// Subscribes to this user's personal channel to receive offers, answers,
  /// ICE candidates, hangups and declines. Idempotent: safe to call on
  /// every sign-in / rebuild.
  Future<void> startListening() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return;
    if (_listeningUserId == uid && _myChannel != null) return;
    await stopListening();
    _listeningUserId = uid;
    final channel = _client.channel('call:user:$uid');
    for (final event in ['offer', 'answer', 'ice', 'hangup', 'decline']) {
      channel.onBroadcast(
          event: event, callback: (payload) => _handleBroadcast(payload));
    }
    channel.subscribe();
    _myChannel = channel;
  }

  Future<void> stopListening() async {
    final channel = _myChannel;
    _myChannel = null;
    _listeningUserId = null;
    if (channel != null) {
      try {
        await _client.removeChannel(channel);
      } catch (_) {}
    }
    // Peer channels are created per call in [_sendSignal] and must not
    // outlive sign-out either (finding #12).
    await _closeAllPeerChannels();
  }

  /// Removes and unsubscribes every peer signalling channel.
  Future<void> _closeAllPeerChannels() async {
    final channels = _peerChannels.values.toList();
    _peerChannels.clear();
    for (final channel in channels) {
      try {
        await _client.removeChannel(channel);
      } catch (_) {}
    }
  }

  /// Removes and unsubscribes the signalling channel for one peer.
  Future<void> _removePeerChannel(String peerId) async {
    final channel = _peerChannels.remove(peerId);
    if (channel == null) return;
    try {
      await _client.removeChannel(channel);
    } catch (_) {}
  }

  void _handleBroadcast(Map<String, dynamic> payload) {
    final signal = parseCallSignal(payload);
    if (signal == null) return;
    if (signal.to != _client.auth.currentUser?.id) return;
    // Every handler is async and was previously fire-and-forget: an
    // unhandled error inside one could kill the isolate (finding #2).
    // Guard each call so a bad signal can never crash the app.
    switch (signal.type) {
      case CallSignalType.offer:
        unawaited(_handleOffer(signal).catchError((_) {}));
        break;
      case CallSignalType.answer:
        unawaited(_handleAnswer(signal).catchError((_) {}));
        break;
      case CallSignalType.ice:
        unawaited(_handleIce(signal).catchError((_) {}));
        break;
      case CallSignalType.hangup:
        unawaited(_handleRemoteHangup(signal).catchError((_) {}));
        break;
      case CallSignalType.decline:
        unawaited(_handleDecline(signal).catchError((_) {}));
        break;
    }
  }

  Future<void> _sendSignal(CallSignal signal) async {
    // A failed broadcast (socket down, channel gone) must never throw
    // into a fire-and-forget caller such as pc.onIceCandidate (#2).
    try {
      final peerId = signal.to;
      var channel = _peerChannels[peerId];
      if (channel == null) {
        // Broadcasts go to the peer's personal channel. subscribe() is
        // called first, but sendBroadcastMessage falls back to the Realtime
        // REST endpoint when the socket has not joined yet, so the offer
        // does not depend on the join racing the send.
        channel = _client.channel('call:user:$peerId');
        channel.subscribe();
        _peerChannels[peerId] = channel;
      }
      await channel.sendBroadcastMessage(
          event: signal.type.name, payload: encodeCallSignal(signal));
    } catch (_) {}
  }

  // -- Incoming call ---------------------------------------------------------

  Future<void> _handleOffer(CallSignal signal) async {
    // Busy in another call: decline immediately so the caller is not left
    // ringing, and never overwrite the call already in progress.
    if (state.value != CallState.idle) {
      // Write the history row before sending the decline (#10), so the
      // caller does not time out with the row stuck as 'missed'. The
      // row id / finalized flag belong to the call in progress, so save
      // and restore them around this one-off update.
      final prevRowId = currentCallRowId;
      final prevFinalized = _rowFinalized;
      currentCallRowId = signal.callId;
      _rowFinalized = false;
      try {
        await _updateCallRow('declined', end: true);
      } catch (_) {}
      currentCallRowId = prevRowId;
      _rowFinalized = prevFinalized;
      await _sendSignal(CallSignal(
          type: CallSignalType.decline,
          from: signal.to,
          to: signal.from,
          callId: signal.callId,
          callType: signal.callType));
      return;
    }
    currentCallId = signal.callId;
    currentPeerId = signal.from;
    currentCallType = signal.callType;
    currentCallRowId = signal.callId;
    _answered = false;
    endReason = null;
    callError.value = null;
    incomingCall.value = signal;
    incomingCallerName.value = null;
    state.value = CallState.incoming;
    _loadCallerName(signal.from);
    // Tactile alert on offer. There is no ringtone mechanism in the app
    // (no audio asset / ringtone package) — a real ringtone is still
    // pending and is NOT faked here (findings #8/#9).
    unawaited(HapticFeedback.vibrate().catchError((_) {}));
    _armRingTimer(() async {
      // Unanswered: the callee marks it missed, then dismisses the overlay.
      await _updateCallRow('missed', end: true);
      endReason = 'missed';
      incomingCall.value = null;
      _pendingIncomingCall = null;
      _pendingOverlayTimer?.cancel();
      _resetCall();
    });
    _showIncomingOverlay(signal);
  }

  Future<void> _loadCallerName(String userId) async {
    try {
      final row = await _client
          .from('profiles')
          .select('display_name,username')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) return;
      final name = row['display_name']?.toString().trim().isNotEmpty == true
          ? row['display_name'].toString()
          : (row['username']?.toString().isNotEmpty == true
              ? '@${row['username']}'
              : null);
      if (name != null) incomingCallerName.value = name;
    } catch (_) {
      // The overlay falls back to the caller id; a missing name must not
      // block the call.
    }
  }

  void _showIncomingOverlay(CallSignal signal) {
    final context = helbaNavigatorKey.currentContext;
    if (context == null) {
      // No navigator yet (login / loading / banned screen): queue the
      // offer instead of silently dropping it (#9) and retry until a
      // context appears or the call ends (ring timeout / decline).
      _pendingIncomingCall = signal;
      _scheduleOverlayRetry();
      return;
    }
    if (_overlayShowing) {
      if (_pendingIncomingCall?.callId != signal.callId) {
        _pendingIncomingCall = signal;
      }
      return;
    }
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    _overlayShowing = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => IncomingCallDialog(signal: signal),
    ).then((_) {
      _overlayShowing = false;
      // An offer queued while the dialog was up gets its chance now.
      final pending = _pendingIncomingCall;
      if (pending != null &&
          incomingCall.value != null &&
          state.value == CallState.incoming) {
        _showIncomingOverlay(pending);
      }
    });
  }

  /// Retries a queued incoming-call overlay once a second until it can
  /// be shown or the incoming call is gone. Bounded by the ring timer,
  /// which clears the pending offer on timeout.
  void _scheduleOverlayRetry() {
    _pendingOverlayTimer?.cancel();
    _pendingOverlayTimer = Timer(const Duration(seconds: 1), () {
      final pending = _pendingIncomingCall;
      if (pending == null ||
          incomingCall.value == null ||
          state.value != CallState.incoming) {
        return;
      }
      _showIncomingOverlay(pending);
      if (_pendingIncomingCall != null) _scheduleOverlayRetry();
    });
  }

  /// Lets the UI layer poll/retry a queued incoming call, e.g. after the
  /// navigator becomes available. No-op when nothing is queued.
  void retryPendingIncomingOverlay() {
    final pending = _pendingIncomingCall;
    if (pending != null) _showIncomingOverlay(pending);
  }

  /// True while an incoming offer is queued waiting for a navigator.
  bool get hasPendingIncomingCall => _pendingIncomingCall != null;

  /// Accepts a ringing incoming call. Returns false when the microphone
  /// (or camera, for video) permission is denied — the call is declined
  /// automatically in that case. On success the caller opens [CallPage].
  Future<bool> acceptCall(CallSignal signal) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return false;
    _ringTimer?.cancel();
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    callError.value = null;
    final video = signal.callType == 'video';
    if (!await _ensurePermissions(video: video)) {
      await declineCall(signal);
      return false;
    }
    try {
      await _setupPeerConnection(
          peerId: signal.from, callType: signal.callType);
      final sdp = signal.sdp;
      if (sdp == null) throw StateError('Missing offer SDP');
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, signal.sdpType ?? 'offer'));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _sendSignal(CallSignal(
          type: CallSignalType.answer,
          from: myId,
          to: signal.from,
          callId: signal.callId,
          callType: signal.callType,
          payload: {'sdp': answer.sdp, 'type': answer.type}));
      await _updateCallRow('ongoing');
      _answered = true;
      incomingCall.value = null;
      state.value = CallState.active;
      return true;
    } catch (_) {
      await _closePeerConnection();
      await declineCall(signal);
      return false;
    }
  }

  /// Declines a ringing incoming call: tells the caller and marks the
  /// history row declined, then dismisses the overlay.
  Future<void> declineCall([CallSignal? signal]) async {
    final incoming = signal ?? incomingCall.value;
    if (incoming == null) return;
    _ringTimer?.cancel();
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    final myId = _client.auth.currentUser?.id;
    if (myId != null) {
      try {
        await _sendSignal(CallSignal(
            type: CallSignalType.decline,
            from: myId,
            to: incoming.from,
            callId: incoming.callId,
            callType: incoming.callType));
      } catch (_) {}
    }
    currentCallRowId = incoming.callId;
    await _updateCallRow('declined', end: true);
    endReason = 'declined';
    incomingCall.value = null;
    _resetCall();
  }

  // -- Outgoing call ---------------------------------------------------------

  /// Starts a call to [calleeId]. Returns the call id (the `calls` row id,
  /// also used as the signalling call id) on success, or null when the
  /// microphone/camera permission is denied, the user is signed out, or a
  /// call is already in progress. Throws when the history row cannot be
  /// created (e.g. migration 010 not applied); the caller shows a
  /// SnackBar for that.
  Future<String?> startCall({
    required String calleeId,
    required String calleeName,
    required String callType,
  }) async {
    final myId = _client.auth.currentUser?.id;
    // Synchronous guard against double-tap (#5): claim the call before
    // the first await, so a second rapid tap sees `outgoing`/`_starting`
    // instead of passing the idle check and starting a second call.
    if (myId == null || _starting || state.value != CallState.idle) {
      return null;
    }
    _starting = true;
    state.value = CallState.outgoing;
    callError.value = null;
    final video = callType == 'video';
    try {
      if (!await _ensurePermissions(video: video)) {
        _resetCall();
        return null;
      }
      final row = await _client.from('calls').insert({
        'caller_id': myId,
        'callee_id': calleeId,
        'type': callType,
        'status': 'ringing',
      }).select('id').single();
      final callId = row['id'].toString();
      currentCallId = callId;
      currentPeerId = calleeId;
      currentPeerName = calleeName;
      currentCallType = callType;
      currentCallRowId = callId;
      _answered = false;
      endReason = null;
      try {
        await _setupPeerConnection(peerId: calleeId, callType: callType);
        final offer = await _pc!.createOffer();
        await _pc!.setLocalDescription(offer);
        await _sendSignal(CallSignal(
            type: CallSignalType.offer,
            from: myId,
            to: calleeId,
            callId: callId,
            callType: callType,
            payload: {'sdp': offer.sdp, 'type': offer.type}));
      } catch (_) {
        await _closePeerConnection();
        await _updateCallRow('cancelled', end: true);
        _resetCall();
        rethrow;
      }
      _armRingTimer(() async {
        // Nobody answered: mark it missed and end the outgoing screen.
        await _updateCallRow('missed', end: true);
        endReason = 'missed';
        await hangUp(sendSignal: true);
      });
      return callId;
    } catch (_) {
      // Row creation / any other failure before the offer: the inner
      // catch already reset for setup failures; this restores idle for
      // the rest (e.g. the history-row insert throwing) and rethrows so
      // the caller can show its SnackBar, as before.
      _resetCall();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  // -- Remote signals --------------------------------------------------------

  Future<void> _handleAnswer(CallSignal signal) async {
    // Late answer (#11): we already ended (e.g. ring timeout) while the
    // callee answered. Tell them to end too instead of leaving them
    // alone in an "active" call.
    if (state.value == CallState.ended) {
      final myId = _client.auth.currentUser?.id;
      if (myId != null) {
        try {
          await _sendSignal(CallSignal(
              type: CallSignalType.hangup,
              from: myId,
              to: signal.from,
              callId: signal.callId,
              callType: signal.callType));
        } catch (_) {}
      }
      return;
    }
    if (state.value != CallState.outgoing ||
        signal.callId != currentCallId) {
      return;
    }
    final sdp = signal.sdp;
    if (sdp == null || _pc == null) {
      // An answer without usable SDP can never connect: end the call
      // instead of stranding the caller on "جارٍ الاتصال…".
      await hangUp(sendSignal: true);
      return;
    }
    try {
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, signal.sdpType ?? 'answer'));
      // Cancel the ring timer only after the answer proved usable (#6):
      // cancelling before setRemoteDescription stranded the caller when
      // a bad answer threw.
      _ringTimer?.cancel();
      await _updateCallRow('ongoing');
      _answered = true;
      state.value = CallState.active;
    } catch (_) {
      // A bad answer must not leave the caller ringing forever: end it.
      try {
        await hangUp(sendSignal: true);
      } catch (_) {}
    }
  }

  Future<void> _handleIce(CallSignal signal) async {
    if (signal.callId != currentCallId || _pc == null) return;
    final candidate = signal.candidate;
    if (candidate == null) return;
    try {
      await _pc!.addCandidate(RTCIceCandidate(candidate['candidate']
              ?.toString(),
          candidate['sdpMid']?.toString(),
          candidate['sdpMLineIndex'] is int
              ? candidate['sdpMLineIndex'] as int
              : int.tryParse(
                  candidate['sdpMLineIndex']?.toString() ?? '')));
    } catch (_) {
      // A stale candidate (e.g. after hangup) is harmless.
    }
  }

  /// The other side hung up. They already wrote the final history status,
  /// so this side only cleans up locally and ends its screen.
  Future<void> _handleRemoteHangup(CallSignal signal) async {
    if (signal.callId != currentCallId &&
        signal.callId != incomingCall.value?.callId) {
      return;
    }
    _ringTimer?.cancel();
    // Still ringing (never answered) is a missed call, not a plain end.
    endReason = _answered ? 'ended' : 'missed';
    incomingCall.value = null;
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    await _closePeerConnection();
    state.value = CallState.ended;
    _scheduleIdleReset();
    _clearCurrentCall();
  }

  /// The callee declined our outgoing call. They already marked the row
  /// declined; this side only ends its screen.
  Future<void> _handleDecline(CallSignal signal) async {
    if (state.value != CallState.outgoing ||
        signal.callId != currentCallId) {
      return;
    }
    _ringTimer?.cancel();
    endReason = 'declined';
    await _closePeerConnection();
    state.value = CallState.ended;
    _scheduleIdleReset();
    _clearCurrentCall();
  }

  // -- Ending a call -----------------------------------------------------------

  /// Ends the current call: tells the peer, closes the peer connection,
  /// writes the final history status (completed when answered, cancelled
  /// when it never was) and moves the state to ended so the call screen
  /// pops itself.
  Future<void> hangUp({bool sendSignal = true}) async {
    _ringTimer?.cancel();
    _connectionTimer?.cancel();
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    final peerId = currentPeerId;
    final callId = currentCallId;
    final myId = _client.auth.currentUser?.id;
    if (sendSignal && peerId != null && callId != null && myId != null) {
      try {
        await _sendSignal(CallSignal(
            type: CallSignalType.hangup,
            from: myId,
            to: peerId,
            callId: callId,
            callType: currentCallType ?? 'voice'));
      } catch (_) {}
    }
    if (_answered) {
      await _updateCallRow('completed', end: true);
    } else if (currentCallRowId != null &&
        state.value == CallState.outgoing) {
      // Skip when the row already has a final status (e.g. the ring
      // timeout already marked it 'missed' before calling hangUp).
      await _updateCallRow('cancelled', end: true);
    }
    endReason ??= 'ended';
    await _closePeerConnection();
    state.value = CallState.ended;
    _scheduleIdleReset();
    _clearCurrentCall();
  }

  /// Resets the state machine to idle shortly after a call ends (#4).
  /// CallPage pops on `ended`, so the reset is delayed ~300ms to let it
  /// read the final state first. Guarded: a new call that started in
  /// the meantime (state no longer `ended`, or a different call row)
  /// is never clobbered.
  void _scheduleIdleReset() {
    final rowIdAtEnd = currentCallRowId;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (state.value != CallState.ended) return;
      if (rowIdAtEnd != null &&
          currentCallRowId != null &&
          currentCallRowId != rowIdAtEnd) {
        return;
      }
      _resetCall();
    });
  }

  /// Safety net for the call screen: back to idle only if the call
  /// already ended. CallPage.dispose() calls this.
  void resetToIdleIfEnded() {
    if (state.value == CallState.ended) _resetCall();
  }

  // -- In-call controls ------------------------------------------------------

  void toggleMute() {
    final muted = !isMuted.value;
    isMuted.value = muted;
    for (final track in _local?.getAudioTracks() ?? const []) {
      track.enabled = !muted;
    }
  }

  void toggleCamera() {
    final off = !isCameraOff.value;
    isCameraOff.value = off;
    for (final track in _local?.getVideoTracks() ?? const []) {
      track.enabled = !off;
    }
  }

  Future<void> toggleSpeaker() async {
    final on = !isSpeakerOn.value;
    // Flip the UI only after the Helper call succeeds (#7): on failure
    // (e.g. MODIFY_AUDIO_SETTINGS missing) the old code flipped anyway
    // and the speaker button lied about the actual audio route.
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {
      return;
    }
    isSpeakerOn.value = on;
  }

  // -- Internals ---------------------------------------------------------------

  Future<bool> _ensurePermissions({required bool video}) async {
    // flutter_webrtc only declares the manifest entries; Android runtime
    // permission for these dangerous permissions is the app's job, so ask
    // here before getUserMedia, every time, for microphone (+ camera).
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    if (video) {
      final camera = await Permission.camera.request();
      if (!camera.isGranted) return false;
    }
    return true;
  }

  Future<void> _setupPeerConnection({
    required String peerId,
    required String callType,
  }) async {
    final video = callType == 'video';
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video ? {'facingMode': 'user'} : false,
    });
    _local = stream;
    localStream.value = stream;
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      // STUN only: no TURN server is configured for Helba. Calls may fail
      // on strict symmetric-NAT networks; that is a known, honest limit.
    });
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      final myId = _client.auth.currentUser?.id;
      final callId = currentCallId;
      if (myId == null || callId == null) return;
      unawaited(_sendSignal(CallSignal(
          type: CallSignalType.ice,
          from: myId,
          to: peerId,
          callId: callId,
          callType: callType,
          payload: {'candidate': candidate.toMap()})));
    };
    pc.onAddStream = (stream) => remoteStream.value = stream;
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) remoteStream.value = event.streams.first;
    };
    // End the call (with a message) if the connection fails or stays
    // disconnected, instead of a silent black screen / silence (#11).
    pc.onConnectionState = _onConnectionState;
    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _onConnectionState(
            RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      }
    };
    // addStream is deprecated (pre-Unified-Plan): add each track (#13).
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    // Voice calls default to the earpiece, video calls to the speaker.
    // Only record the route after the Helper call succeeds (#7).
    try {
      await Helper.setSpeakerphoneOn(video);
      isSpeakerOn.value = video;
    } catch (_) {
      isSpeakerOn.value = false;
    }
    isMuted.value = false;
    isCameraOff.value = false;
  }

  void _onConnectionState(RTCPeerConnectionState connectionState) {
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _connectionTimer?.cancel();
      unawaited(_endWithConnectionError().catchError((_) {}));
    } else if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      // Brief drops recover on their own; only end after 5s down.
      _connectionTimer?.cancel();
      _connectionTimer = Timer(const Duration(seconds: 5), () {
        if ((state.value == CallState.active ||
                state.value == CallState.outgoing) &&
            _pc?.connectionState ==
                RTCPeerConnectionState
                    .RTCPeerConnectionStateDisconnected) {
          unawaited(_endWithConnectionError().catchError((_) {}));
        }
      });
    } else if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _connectionTimer?.cancel();
    }
  }

  Future<void> _endWithConnectionError() async {
    if (state.value != CallState.active &&
        state.value != CallState.outgoing) {
      return;
    }
    callError.value = 'تعذّر الاتصال';
    try {
      await hangUp(sendSignal: true);
    } catch (_) {}
  }

  Future<void> _closePeerConnection() async {
    final pc = _pc;
    _pc = null;
    _connectionTimer?.cancel();
    // The peer signalling channel was created for this call: remove and
    // unsubscribe it here so channels do not leak per call (#12).
    // hangUp() sends its hangup signal before calling this, so removing
    // the channel now cannot drop that signal.
    final peerId = currentPeerId;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
    final local = _local;
    _local = null;
    if (local != null) {
      for (final track in local.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await local.dispose();
      } catch (_) {}
    }
    localStream.value = null;
    remoteStream.value = null;
    if (peerId != null) await _removePeerChannel(peerId);
  }

  void _armRingTimer(Future<void> Function() onTimeout) {
    _ringTimer?.cancel();
    _ringTimer = Timer(callRingTimeout, () {
      // Guard the fire-and-forget timeout so an error in it cannot
      // become an unhandled async error (#2).
      unawaited(onTimeout().catchError((_) {}));
    });
  }

  Future<void> _updateCallRow(String status, {bool end = false}) async {
    final rowId = currentCallRowId;
    if (rowId == null || _rowFinalized) return;
    if (end) _rowFinalized = true;
    try {
      await _client.from('calls').update({
        'status': status,
        if (end) 'ended_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', rowId);
    } catch (_) {
      // History is best-effort; a failed update must never break the call.
    }
  }

  void _resetCall() {
    _ringTimer?.cancel();
    _connectionTimer?.cancel();
    _pendingOverlayTimer?.cancel();
    _pendingIncomingCall = null;
    _clearCurrentCall();
    state.value = CallState.idle;
  }

  void _clearCurrentCall() {
    currentCallId = null;
    currentPeerId = null;
    currentPeerName = null;
    currentCallType = null;
    currentCallRowId = null;
    _answered = false;
    _rowFinalized = false;
  }
}

// ---------------------------------------------------------------------------
// Incoming-call overlay: shown via the navigator key from anywhere in the
// app. Dismisses itself when the service clears [CallService.incomingCall]
// (decline elsewhere, ring timeout, remote hangup).
// ---------------------------------------------------------------------------

class IncomingCallDialog extends StatefulWidget {
  final CallSignal signal;
  const IncomingCallDialog({super.key, required this.signal});
  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    CallService.instance.incomingCall.addListener(_onIncomingChanged);
  }

  @override
  void dispose() {
    CallService.instance.incomingCall.removeListener(_onIncomingChanged);
    super.dispose();
  }

  void _onIncomingChanged() {
    if (CallService.instance.incomingCall.value == null && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Capture the app navigator and messenger before popping: this
    // dialog's State is unmounted by the pop, so nothing below may use
    // `mounted` or this dialog's context.
    final navigator = helbaNavigatorKey.currentState;
    final rootContext = helbaNavigatorKey.currentContext;
    final messenger = rootContext == null
        ? null
        : ScaffoldMessenger.of(rootContext);
    // Close the overlay first: acceptCall clears incomingCall, which would
    // also pop this dialog through the listener.
    Navigator.of(context).pop();
    final accepted =
        await CallService.instance.acceptCall(widget.signal);
    if (!accepted) {
      // Permission denied: acceptCall already declined the call.
      messenger?.showSnackBar(
        const SnackBar(
            content: Text('تعذّر الوصول إلى الميكروفون أو الكاميرا.')),
      );
      return;
    }
    navigator?.push(MaterialPageRoute(
        builder: (_) => CallPage(
              callId: widget.signal.callId,
              peerId: widget.signal.from,
              peerName: CallService.instance.incomingCallerName.value ??
                  widget.signal.from,
              callType: widget.signal.callType,
            )));
  }

  @override
  Widget build(BuildContext context) {
    final service = CallService.instance;
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 36,
            child: Icon(
                widget.signal.callType == 'video'
                    ? Icons.videocam
                    : Icons.call,
                size: 36),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: service.incomingCallerName,
            builder: (_, name, __) => Text(
              name ?? 'متصل غير معروف',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 4),
          Text(callTypeLabel(widget.signal.callType),
              style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            Column(children: [
              FloatingActionButton(
                heroTag: 'decline_call',
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                onPressed: _busy
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        unawaited(service.declineCall(widget.signal));
                      },
                child: const Icon(Icons.call_end),
              ),
              const SizedBox(height: 6),
              const Text('رفض'),
            ]),
            Column(children: [
              FloatingActionButton(
                heroTag: 'accept_call',
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                onPressed: _busy ? null : _accept,
                child: const Icon(Icons.call),
              ),
              const SizedBox(height: 6),
              const Text('قبول'),
            ]),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Call screen.
// ---------------------------------------------------------------------------

/// Formats a call duration as mm:ss.
String formatCallDuration(Duration duration) {
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class CallPage extends StatefulWidget {
  final String callId;
  final String peerId;
  final String peerName;
  final String callType;
  final bool isCaller;
  const CallPage({
    super.key,
    required this.callId,
    required this.peerId,
    required this.peerName,
    required this.callType,
    this.isCaller = false,
  });
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  // Renderer lifecycle (#1/#3): initialize() is async and only assigns
  // the texture id when it completes; assigning srcObject before that
  // throws 'Call initialize before setting the stream'. Track each
  // renderer separately, assign only after it is ready, and never touch
  // a renderer after dispose.
  bool _localRendererReady = false;
  bool _remoteRendererReady = false;
  bool _disposed = false;
  // Final status captured when the call ends (#14): the service resets
  // to idle ~300ms after `ended`, so the screen keeps its own copy to
  // show while it pops (including the connection-error message).
  String? _endStatusText;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _activeSince;

  CallService get _service => CallService.instance;

  @override
  void initState() {
    super.initState();
    // Voice calls never show video: skip renderer init entirely (#1).
    unawaited(_initRenderers().catchError((_) {}));
    _service.localStream.addListener(_updateRenderers);
    _service.remoteStream.addListener(_updateRenderers);
    _service.state.addListener(_onStateChanged);
    _onStateChanged();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_activeSince != null && mounted) {
        setState(
            () => _elapsed = DateTime.now().difference(_activeSince!));
      }
    });
  }

  /// Awaits both renderer initializations (video only). If dispose
  /// happens first, the just-initialized renderer is disposed right
  /// away instead of being left live on a dead page (#3).
  Future<void> _initRenderers() async {
    if (widget.callType != 'video') return;
    var localOk = false;
    try {
      await _localRenderer.initialize();
      localOk = true;
    } catch (_) {}
    if (_disposed) {
      if (localOk) await _disposeRenderer(_localRenderer);
      return;
    }
    _localRendererReady = localOk;
    var remoteOk = false;
    try {
      await _remoteRenderer.initialize();
      remoteOk = true;
    } catch (_) {}
    if (_disposed) {
      if (localOk) await _disposeRenderer(_localRenderer);
      if (remoteOk) await _disposeRenderer(_remoteRenderer);
      return;
    }
    _remoteRendererReady = remoteOk;
    _updateRenderers();
  }

  Future<void> _disposeRenderer(RTCVideoRenderer renderer) async {
    try {
      await renderer.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _service.localStream.removeListener(_updateRenderers);
    _service.remoteStream.removeListener(_updateRenderers);
    _service.state.removeListener(_onStateChanged);
    // Only dispose renderers that finished initializing, via the async
    // helper, so dispose cannot race a pending initialize() (#3).
    // Voice calls never initialized them.
    if (_localRendererReady) unawaited(_disposeRenderer(_localRenderer));
    if (_remoteRendererReady) unawaited(_disposeRenderer(_remoteRenderer));
    // Safety net (#4): if this page is going away with the call ended,
    // do not leave the service bricked at `ended`.
    _service.resetToIdleIfEnded();
    super.dispose();
  }

  void _updateRenderers() {
    if (_disposed) return;
    final local = _service.localStream.value;
    if (local != null &&
        _localRendererReady &&
        _localRenderer.srcObject != local) {
      _localRenderer.srcObject = local;
    }
    final remote = _service.remoteStream.value;
    if (remote != null &&
        _remoteRendererReady &&
        _remoteRenderer.srcObject != remote) {
      _remoteRenderer.srcObject = remote;
    }
  }

  void _onStateChanged() {
    final state = _service.state.value;
    if (state == CallState.active && _activeSince == null) {
      _activeSince = DateTime.now();
    }
    if (state == CallState.ended && mounted) {
      // Capture the end reason / error now (#14/#11): the service
      // resets to idle 300ms later, which would otherwise erase it.
      _endStatusText = _service.callError.value ??
          (_service.endReason == 'missed'
              ? 'مكالمة فائتة'
              : _service.endReason == 'declined'
                  ? 'تم رفض المكالمة'
                  : 'انتهت المكالمة');
      // Give the user a moment to read a connection error; otherwise
      // leave on the next frame, as before.
      if (_service.callError.value != null) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) Navigator.of(context).pop();
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }
  }

  Future<void> _hangUp() async {
    await _service.hangUp();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == 'video';
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        // System back ends the call too; the hangup button is not the only
        // way out of this screen.
        if (didPop && _service.state.value != CallState.ended) {
          unawaited(_service.hangUp());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black87,
        body: SafeArea(
          child: ValueListenableBuilder<CallState>(
            valueListenable: _service.state,
            builder: (_, callState, __) {
              final statusText = callState == CallState.outgoing
                  ? 'جارٍ الاتصال…'
                  : callState == CallState.active
                      ? formatCallDuration(_elapsed)
                      : callState == CallState.ended
                          ? (_endStatusText ?? 'انتهت المكالمة')
                          // After `ended` the service resets to idle
                          // (~300ms) before this page pops; keep showing
                          // the captured end status until then.
                          : (_endStatusText ?? 'مكالمة');
              return Stack(children: [
                if (isVideo)
                  Positioned.fill(
                    child: ValueListenableBuilder<MediaStream?>(
                      valueListenable: _service.remoteStream,
                      builder: (_, remote, __) => remote == null
                          ? const Center(
                              child: Icon(Icons.person,
                                  size: 96, color: Colors.white54))
                          : RTCVideoView(_remoteRenderer),
                    ),
                  )
                else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 52,
                          backgroundColor: Colors.white24,
                          child: Text(
                            widget.peerName.isNotEmpty
                                ? widget.peerName.characters.first
                                : '?',
                            style: const TextStyle(
                                fontSize: 40, color: Colors.white),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(widget.peerName,
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                        const SizedBox(height: 8),
                        Text(statusText,
                            style: const TextStyle(
                                fontSize: 16, color: Colors.white70)),
                      ],
                    ),
                  ),
                if (isVideo)
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Column(children: [
                      Text(widget.peerName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                      Text(statusText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70)),
                    ]),
                  ),
                if (isVideo)
                  Positioned(
                    left: 16,
                    bottom: 120,
                    width: 110,
                    height: 150,
                    child: Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: Colors.white54),
                          borderRadius: BorderRadius.circular(12)),
                      clipBehavior: Clip.antiAlias,
                      child: ValueListenableBuilder<MediaStream?>(
                        valueListenable: _service.localStream,
                        builder: (_, local, __) => local == null
                            ? const Center(
                                child: Icon(Icons.person,
                                    color: Colors.white54))
                            : RTCVideoView(_localRenderer, mirror: true),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Column(children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _service.isMuted,
                          builder: (_, muted, __) => _CallControlButton(
                            icon: muted ? Icons.mic_off : Icons.mic,
                            label: 'كتم',
                            onPressed: _service.toggleMute,
                          ),
                        ),
                        const SizedBox(width: 20),
                        if (isVideo)
                          ValueListenableBuilder<bool>(
                            valueListenable: _service.isCameraOff,
                            builder: (_, off, __) => _CallControlButton(
                              icon: off
                                  ? Icons.videocam_off
                                  : Icons.videocam,
                              label: 'الكاميرا',
                              onPressed: _service.toggleCamera,
                            ),
                          ),
                        if (isVideo) const SizedBox(width: 20),
                        ValueListenableBuilder<bool>(
                          valueListenable: _service.isSpeakerOn,
                          builder: (_, on, __) => _CallControlButton(
                            icon: Icons.volume_up,
                            label: 'مكبر الصوت',
                            active: on,
                            onPressed: () =>
                                unawaited(_service.toggleSpeaker()),
                          ),
                        ),
                        const SizedBox(width: 20),
                        _CallControlButton(
                          icon: Icons.call_end,
                          label: 'إنهاء',
                          backgroundColor: Colors.red,
                          onPressed: _hangUp,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'جودة المكالمة قد تتأثر بدون خادم TURN',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ]),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final bool active;
  const _CallControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
    this.active = false,
  });
  @override
  Widget build(BuildContext context) => Column(children: [
        FloatingActionButton(
          heroTag: label,
          mini: true,
          backgroundColor: backgroundColor ??
              (active ? Colors.white : Colors.white24),
          foregroundColor:
              active && backgroundColor == null ? Colors.black : Colors.white,
          onPressed: onPressed,
          child: Icon(icon),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.white)),
      ]);
}
