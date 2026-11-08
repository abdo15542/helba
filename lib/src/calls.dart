import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player_advanced/flutter_ringtone_player_advanced.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push.dart';

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
/// 60s (was 30s, fix 10): a callee answering from a cold start — push
/// tap, app launch, offer re-request — needs more than 30s, and the
/// pg_cron job that marks ringing calls missed runs every minute, so a
/// 60s window is compatible with it. Do not exceed 60s, or the cron
/// would mark the call missed while the client is still ringing.
const callRingTimeout = Duration(seconds: 60);

/// Video capture target for a video call: 720p at 30fps (ideal values —
/// the camera falls back to a lower resolution when the device cannot
/// provide 720p). The sender bitrate cap ([callVideoMaxBitrate]) bounds
/// the bandwidth regardless of the captured resolution.
const callVideoWidth = 1280;
const callVideoHeight = 720;
const callVideoFrameRate = 30;

/// Maximum video send bitrate in bits per second (2.5 Mbps). Caps the
/// video sender so a video call stays usable on weak networks instead
/// of sending unconstrained high-resolution video.
const callVideoMaxBitrate = 2500000;

/// How long the connection may stay `disconnected` before an ICE restart
/// is attempted (10s). Brief drops recover on their own inside this
/// window; a longer outage means the path is dead and a restart is
/// worth one try. Only one restart is attempted per call.
const disconnectReconnectDelay = Duration(seconds: 10);

/// TURN relay servers, empty until the user chooses a provider. STUN
/// only (see the file header) until entries are added here; each entry
/// is {'urls': 'turn:...', 'username': '...', 'credential': '...'}.
/// Filled in once a TURN provider is chosen — never hardcode a
/// credential from an untrusted source here.
const List<Map<String, String>> turnIceServers = [];

/// Constraints for an ICE-restart offer: a fresh ICE gathering on the
/// same session. Sent as a re-offer for the current callId.
const Map<String, dynamic> iceRestartOfferConstraints = {'iceRestart': true};

/// The navigator key the app's MaterialApp uses, so an incoming call can
/// be shown from anywhere (inbox or inside a chat) without a BuildContext.
final GlobalKey<NavigatorState> helbaNavigatorKey =
    GlobalKey<NavigatorState>();

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// Signalling message kinds. `offer`/`answer` carry SDP, `ice` carries one
/// ICE candidate, `hangup`/`decline` carry no payload, and `requestOffer`
/// asks the caller to resend the offer (the callee answered a call push
/// whose SDP never arrived over Realtime, e.g. the app was closed).
enum CallSignalType { offer, answer, ice, hangup, decline, requestOffer }

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
    case 'requestOffer':
      return CallSignalType.requestOffer;
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

/// Video capture constraints for a video call: 720p at 30fps (ideal).
/// The camera may fall back to a lower resolution when the device
/// cannot provide 720p; the sender bitrate cap ([callVideoMaxBitrate])
/// bounds the bandwidth regardless.
Map<String, dynamic> callVideoConstraints() => {
      'facingMode': 'user',
      'width': {'ideal': callVideoWidth},
      'height': {'ideal': callVideoHeight},
      'frameRate': {'ideal': callVideoFrameRate},
    };

/// True when an ICE restart may be attempted: the call is active or
/// outgoing and no restart has been attempted yet for this call. A
/// restart is attempted at most once per call, so a restart that fails
/// ends the call instead of looping.
bool shouldAttemptIceRestart({
  required bool attempted,
  required bool isActiveCall,
}) =>
    !attempted && isActiveCall;

/// True when an incoming offer is a renegotiation of the call already
/// in progress (an ICE restart): the call is active or outgoing, the
/// callId matches the current call, and the offer carries SDP. Such an
/// offer is answered, never declined as busy.
bool isRenegotiationOffer({
  required CallState state,
  required String? signalCallId,
  required String? currentCallId,
  required String? sdp,
}) =>
    (state == CallState.active || state == CallState.outgoing) &&
    signalCallId != null &&
    signalCallId == currentCallId &&
    sdp != null;

/// The offer SDP stored on a calls row, or null when the row carries
/// none (the caller has not stored it yet, or the value is blank). A
/// non-string or blank/whitespace-only value counts as absent. Pure:
/// unit-tested. Used by [CallService.acceptCall] as the database
/// fallback when the offer never arrived over Realtime broadcast.
String? dbOfferSdp(Map? row) {
  if (row == null) return null;
  final sdp = row['offer_sdp'];
  if (sdp is! String) return null;
  if (sdp.trim().isEmpty) return null;
  return sdp;
}

/// The stored offer SDP type, defaulting to 'offer' when the row
/// carries none (missing, non-string, or blank). Pure: unit-tested.
String dbOfferSdpType(Map? row) {
  final type = row?['offer_sdp_type'];
  if (type is String && type.trim().isNotEmpty) return type;
  return 'offer';
}

/// Terminal call statuses: a row in one of these never changes again
/// (migration 017's transition trigger rejects every move out of them).
bool isTerminalCallStatus(String? status) => switch (status) {
      'completed' || 'missed' || 'declined' || 'cancelled' => true,
      _ => false,
    };

/// True when the calls transition trigger (migration 017) allows moving
/// from [from] to [to]. Staying on the same status is allowed (a no-op
/// re-write). Used by the remote-hangup / decline safety net so it never
/// attempts a transition the database would reject.
bool isValidCallTransition(String? from, String? to) {
  if (from == null || to == null) return false;
  if (from == to) return true;
  if (from == 'ringing') {
    return to == 'ongoing' ||
        to == 'missed' ||
        to == 'declined' ||
        to == 'cancelled';
  }
  if (from == 'ongoing') return to == 'completed';
  return false;
}

/// The JSON body the caller sends to the `send-call-push` Edge Function
/// when a call starts, so the callee is woken even when their app is
/// closed. Pure (no Supabase): unit-tested. The function verifies the
/// caller (JWT or trigger secret) and the calls row before sending.
Map<String, dynamic> buildCallPushBody({
  required String callId,
  required String calleeId,
  required String callerId,
  required String callType,
}) =>
    {
      'call_id': callId,
      'callee_id': calleeId,
      'caller_id': callerId,
      'call_type': callType,
    };

/// Outcome of one `send-call-push` invocation (fixes 7/8). The Edge
/// Function returns `{ok, sent, failed, reason, details}` on every
/// call, so the caller can tell whether the callee was actually woken
/// instead of ringing into the void for 30s. Pure: unit-tested.
class CallPushResult {
  /// False when the function answered with an error, or the request
  /// itself failed (network / timeout / non-2xx).
  final bool ok;

  /// FCM messages accepted for the callee's devices.
  final int sent;

  /// FCM sends that failed (dead token, FCM error).
  final int failed;

  /// Stable reason code when nothing was sent (`no_tokens`,
  /// `call_not_ringing`, `all_failed`), or when the request failed
  /// (`request_failed`, `bad_response`, `no_user`). Null when the push
  /// reached the callee.
  final String? reason;

  const CallPushResult({
    required this.ok,
    required this.sent,
    required this.failed,
    this.reason,
  });

  /// True when at least one FCM message was accepted for the callee.
  bool get reachedCallee => ok && sent > 0;

  /// True when the function answered but nothing was sent.
  bool get nothingSent => ok && sent == 0;
}

/// Parses the `send-call-push` response into a [CallPushResult].
/// Never throws: a malformed response (or a null one) is a failed
/// result, not a crash. Pure (no Supabase): unit-tested.
CallPushResult parseCallPushResult(dynamic data) {
  if (data is! Map) {
    return const CallPushResult(
      ok: false,
      sent: 0,
      failed: 0,
      reason: 'bad_response',
    );
  }
  int asInt(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;
  final ok = data['ok'] == true;
  final sent = asInt(data['sent']);
  final failed = asInt(data['failed']);
  final reason = data['reason']?.toString().trim();
  return CallPushResult(
    ok: ok,
    sent: sent,
    failed: failed,
    reason: reason?.isNotEmpty == true ? reason : null,
  );
}

/// The user-facing warning for a call-push outcome, or null when no
/// warning is needed (the push reached the callee, or the call is
/// already dead so waking them is pointless). Pure: unit-tested.
String? callPushWarningMessage(CallPushResult result) {
  if (result.reachedCallee) return null;
  if (!result.ok) {
    return 'تعذّر إرسال إشعار المكالمة — تحقق من الاتصال وحاول مجدداً.';
  }
  switch (result.reason) {
    case 'no_tokens':
      return 'الهاتف الآخر غير مسجّل لاستقبال الإشعارات — لن يرنّ إن كان التطبيق مغلقاً.';
    case 'all_failed':
      return 'لم يصل إشعار المكالمة إلى الهاتف الآخر — قد يكون مغلقاً أو بلا اتصال.';
    case 'call_not_ringing':
      return null;
    default:
      return 'لم يصل إشعار المكالمة إلى الهاتف الآخر.';
  }
}

/// Plays the device's real system ringtone in a loop while an incoming
/// call rings, and stops it on accept / decline / end / timeout.
///
/// The platform call is injected (defaults to FlutterRingtonePlayer, the
/// system default ringtone, looping on Android) so unit tests can drive
/// the start/stop state machine without a device. A failed playback
/// never throws and never sets [playing]: the caller falls back to
/// vibration (see _handleOffer). Never used for outgoing calls.
class CallRingtone {
  CallRingtone({
    Future<void> Function()? play,
    Future<void> Function()? stop,
  })  : _play = play ?? _defaultPlay,
        _stop = stop ?? _defaultStop;

  static Future<void> _defaultPlay() =>
      FlutterRingtonePlayer().playRingtone(looping: true);

  static Future<void> _defaultStop() => FlutterRingtonePlayer().stop();

  final Future<void> Function() _play;
  final Future<void> Function() _stop;
  bool _playing = false;

  /// True once [start] has succeeded and [stop] has not run since.
  bool get playing => _playing;

  /// Starts the looping ringtone. Idempotent: a second call while it is
  /// already playing does nothing. Never throws.
  Future<void> start() async {
    if (_playing) return;
    try {
      await _play();
      _playing = true;
    } catch (_) {
      // No ringtone (no plugin, no system sound): the caller vibrates.
      _playing = false;
    }
  }

  /// Stops the ringtone. A no-op when it is not playing, so every end
  /// path can call it unconditionally. Never throws.
  Future<void> stop() async {
    if (!_playing) return;
    _playing = false;
    try {
      await _stop();
    } catch (_) {}
  }
}

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

  /// True while the connection is down and an ICE restart is being
  /// attempted (or awaited). The call screen shows "إعادة الاتصال…".
  /// Cleared when the connection recovers or the call ends.
  final ValueNotifier<bool> isReconnecting = ValueNotifier(false);

  /// Why the last call ended ('declined', 'missed', 'ended'); read by the
  /// call screen before it pops. Null while a call is in progress.
  String? endReason;

  /// Last connection-failure message for the call screen to show
  /// ('تعذّر الاتصال'), e.g. when the peer connection fails after the
  /// call was answered. Null unless the call ended this way; cleared
  /// when the next call starts.
  final ValueNotifier<String?> callError = ValueNotifier(null);

  /// Warning for the CALLER when the call push did not reach the callee
  /// (fix 8): no push token registered for them, or every FCM send
  /// failed. The call screen observes this and shows a banner, so the
  /// caller knows the other phone may not ring instead of waiting out
  /// the ring window in silence. Null when the push reached the callee
  /// (or no push was attempted yet). Cleared when the next call starts
  /// and when the call ends.
  final ValueNotifier<String?> callPushWarning = ValueNotifier(null);

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

  /// The looping system ringtone while an incoming call rings. Stopped
  /// on every end path (see [_stopIncomingCallAlert]); never used for
  /// outgoing calls.
  final CallRingtone ringtone = CallRingtone();

  /// The offer SDP (and type) this side sent as caller, kept so a
  /// callee who answered a call push can ask for the offer to be
  /// re-sent ([_handleRequestOffer]). Cleared with the call.
  String? _outgoingOfferSdp;
  String? _outgoingOfferType;

  /// Completes when the re-sent offer arrives while [acceptCall] is
  /// waiting for it (push-triggered accept with no SDP yet). Null when
  /// no accept is waiting.
  Completer<CallSignal>? _pendingOfferCompleter;

  /// True once [startListening] has subscribed to the call-push
  /// notifier (see [_onPendingCallPush]); cleared in [stopListening].
  bool _listeningToCallPush = false;

  bool get isVideoCall => currentCallType == 'video';

  RTCPeerConnection? _pc;
  MediaStream? _local;
  RealtimeChannel? _myChannel;
  final Map<String, RealtimeChannel> _peerChannels = {};
  String? _listeningUserId;
  Timer? _ringTimer;
  Timer? _connectionTimer;

  /// True once an ICE restart has been attempted for the current call.
  /// At most one restart per call; a restart that fails ends the call.
  /// Reset in [_resetCall] so the next call gets a fresh attempt.
  bool _iceRestartAttempted = false;
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
    for (final event in [
      'offer',
      'answer',
      'ice',
      'hangup',
      'decline',
      'requestOffer',
    ]) {
      channel.onBroadcast(
          event: event, callback: (payload) => _handleBroadcast(payload));
    }
    channel.subscribe();
    _myChannel = channel;
    // A call push tap may have arrived before sign-in (or before this
    // listener existed): subscribe to the notifier and pick up a queued
    // value now, the same pattern AuthGate uses for pendingChatId.
    if (!_listeningToCallPush) {
      _listeningToCallPush = true;
      pendingIncomingCallPush.addListener(_onPendingCallPush);
    }
    if (pendingIncomingCallPush.value != null) _onPendingCallPush();
  }

  Future<void> stopListening() async {
    if (_listeningToCallPush) {
      _listeningToCallPush = false;
      pendingIncomingCallPush.removeListener(_onPendingCallPush);
    }
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

  /// A call push was tapped (or arrived in the foreground): consume the
  /// queued payload exactly once and run the incoming-call flow for it.
  void _onPendingCallPush() {
    final payload = pendingIncomingCallPush.value;
    if (payload == null) return;
    pendingIncomingCallPush.value = null;
    unawaited(handlePushIncomingCall(payload).catchError((_) {}));
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
      case CallSignalType.requestOffer:
        unawaited(_handleRequestOffer(signal).catchError((_) {}));
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
    // Re-sent offer for the incoming call already showing (the callee
    // answered a call push and asked for the SDP): deliver it to the
    // waiting accept and to the dialog, instead of treating it as a
    // second call. The ring timer keeps running from the first offer.
    if (state.value == CallState.incoming &&
        currentCallId == signal.callId &&
        signal.sdp != null) {
      incomingCall.value = signal;
      final completer = _pendingOfferCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(signal);
      }
      return;
    }
    // Mid-call re-offer for the call already in progress (an ICE
    // restart): answer it as a renegotiation instead of declining as
    // busy. The call stays active; only the session description is
    // refreshed. A failure here leaves the existing (broken) connection
    // alone — the initiator ends the call if it never recovers.
    if (_pc != null &&
        isRenegotiationOffer(
            state: state.value,
            signalCallId: signal.callId,
            currentCallId: currentCallId,
            sdp: signal.sdp)) {
      try {
        // isRenegotiationOffer verified sdp != null.
        await _pc!.setRemoteDescription(
            RTCSessionDescription(signal.sdp!, 'offer'));
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        final myId = _client.auth.currentUser?.id;
        if (myId == null) return;
        await _sendSignal(CallSignal(
            type: CallSignalType.answer,
            from: myId,
            to: signal.from,
            callId: signal.callId,
            callType: signal.callType,
            payload: {'sdp': answer.sdp, 'type': answer.type}));
      } catch (_) {
        // Swallowed: see the comment above.
      }
      return;
    }
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
    await _beginIncomingCall(signal);
  }

  /// Shared incoming-call setup for a Realtime offer and for a call push
  /// tap: ringing state, the real system ringtone (looping) plus
  /// vibration, the ring timer, and the overlay. [callerName] is the name
  /// the push already carried (null for a Realtime offer, where it is
  /// loaded from profiles). [ringTimeout] is the remaining ring window
  /// for a push-triggered call (the caller's 30s window may be partly
  /// spent); a Realtime offer always gets the full [callRingTimeout].
  Future<void> _beginIncomingCall(
    CallSignal signal, {
    String? callerName,
    Duration? ringTimeout,
  }) async {
    currentCallId = signal.callId;
    currentPeerId = signal.from;
    currentCallType = signal.callType;
    currentCallRowId = signal.callId;
    _answered = false;
    endReason = null;
    callError.value = null;
    incomingCall.value = signal;
    incomingCallerName.value =
        callerName?.trim().isNotEmpty == true ? callerName : null;
    state.value = CallState.incoming;
    if (incomingCallerName.value == null) _loadCallerName(signal.from);
    // The device's real system ringtone, looping until the call is
    // answered / declined / ends / times out. A failed playback falls
    // back to vibration only — the call itself never depends on sound.
    // Outgoing calls never ring.
    unawaited(ringtone.start().catchError((_) {}));
    unawaited(HapticFeedback.vibrate().catchError((_) {}));
    // Tell push.dart a call is already ringing, so a foreground call
    // push for the same call does not duplicate this overlay with a
    // second notification.
    callRinging.value = true;
    // The tray notification (if one was shown for this push) is
    // redundant once the overlay is up.
    unawaited(cancelCallNotification(signal.callId).catchError((_) {}));
    _armRingTimer(() async {
      // Unanswered: the callee marks it missed, then dismisses the overlay.
      await _updateCallRow('missed', end: true);
      endReason = 'missed';
      incomingCall.value = null;
      _pendingIncomingCall = null;
      _pendingOverlayTimer?.cancel();
      _resetCall();
    }, timeout: ringTimeout);
    _showIncomingOverlay(signal);
  }

  /// Stops everything an incoming call started: the looping ringtone,
  /// the "already ringing" flag, and the tray notification for this
  /// call (if one was shown). Idempotent: every end path calls it.
  Future<void> _stopIncomingCallAlert() async {
    final callId = currentCallId;
    callRinging.value = false;
    await ringtone.stop();
    if (callId != null) {
      await cancelCallNotification(callId);
    }
  }

  /// Handles an incoming call that arrived as a push (the app was closed
  /// or backgrounded, so the Realtime offer never reached it). Verifies
  /// the call is still ringing in the `calls` table — a stale push is
  /// ignored — then shows the same overlay as a Realtime offer, with
  /// the remaining ring window from the row's `started_at`. The offer
  /// SDP is fetched on accept (see [acceptCall] / [_handleRequestOffer]).
  Future<void> handlePushIncomingCall(CallPushPayload payload) async {
    if (state.value != CallState.idle) return;
    final myId = _client.auth.currentUser?.id;
    if (myId == null || payload.callerId == myId) return;
    Map<String, dynamic>? row;
    try {
      row = await _client
          .from('calls')
          .select('status,caller_id,callee_id,type,started_at')
          .eq('id', payload.callId)
          .maybeSingle();
    } catch (_) {
      return;
    }
    if (row == null) return;
    if (row['status']?.toString() != 'ringing') return;
    if (row['callee_id']?.toString() != myId) return;
    if (row['caller_id']?.toString() != payload.callerId) return;
    final type = row['type']?.toString() == 'video' ? 'video' : 'voice';
    final signal = CallSignal(
      type: CallSignalType.offer,
      from: payload.callerId,
      to: myId,
      callId: payload.callId,
      callType: type,
    );
    var ringTimeout = callRingTimeout;
    final startedAt = DateTime.tryParse(row['started_at']?.toString() ?? '');
    if (startedAt != null) {
      final remaining =
          callRingTimeout - DateTime.now().difference(startedAt);
      if (remaining <= Duration.zero) return;
      ringTimeout = remaining;
    }
    await _beginIncomingCall(
      signal,
      callerName: payload.callerName,
      ringTimeout: ringTimeout,
    );
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
  /// automatically in that case — or when the offer never arrives (a
  /// push-triggered accept whose caller is gone). On success the caller
  /// opens [CallPage].
  Future<bool> acceptCall(CallSignal signal) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return false;
    _ringTimer?.cancel();
    _pendingIncomingCall = null;
    _pendingOverlayTimer?.cancel();
    callError.value = null;
    // The call is being answered: stop the ringtone immediately.
    unawaited(_stopIncomingCallAlert());
    // Resolve the latest offer: a push-triggered dialog may hold a
    // signal without SDP (the offer never arrived over Realtime), while
    // a re-sent offer already updated [incomingCall] with one.
    var effective = signal;
    final current = incomingCall.value;
    if (current != null &&
        current.callId == signal.callId &&
        current.sdp != null) {
      effective = current;
    }
    if (effective.sdp == null) {
      // Database fallback first: the caller stores the offer SDP on
      // the calls row at call start, so a callee whose Realtime offer
      // never arrived (Realtime timed out) can fetch it with a plain
      // select instead of waiting on the requestOffer resend. A
      // missing row or a failed select falls through to the
      // requestOffer wait below.
      try {
        final row = await _client
            .from('calls')
            .select('offer_sdp,offer_sdp_type')
            .eq('id', signal.callId)
            .maybeSingle();
        final dbSdp = dbOfferSdp(row);
        if (dbSdp != null) {
          effective = CallSignal(
            type: CallSignalType.offer,
            from: signal.from,
            to: myId,
            callId: signal.callId,
            callType: signal.callType,
            payload: {'sdp': dbSdp, 'type': dbOfferSdpType(row)},
          );
        }
      } catch (_) {
        // Fall through to the requestOffer wait below.
      }
    }
    if (effective.sdp == null) {
      // No SDP yet: ask the caller to resend the stored offer and wait
      // for it (bounded). The caller is still ringing, so the offer
      // should arrive immediately; a timeout means they are gone.
      final completer = _pendingOfferCompleter = Completer<CallSignal>();
      try {
        await _sendSignal(CallSignal(
            type: CallSignalType.requestOffer,
            from: myId,
            to: signal.from,
            callId: signal.callId,
            callType: signal.callType));
        // 20s (was 10s, fix 10): a push-triggered accept needs the
        // cold-start budget — app launch plus the caller re-sending the
        // offer — and the 60s ring window leaves room for it.
        effective =
            await completer.future.timeout(const Duration(seconds: 20));
      } catch (_) {
        _pendingOfferCompleter = null;
        await declineCall(signal);
        return false;
      } finally {
        _pendingOfferCompleter = null;
      }
      if (effective.sdp == null) {
        await declineCall(signal);
        return false;
      }
    }
    final video = effective.callType == 'video';
    if (!await _ensurePermissions(video: video)) {
      await declineCall(signal);
      return false;
    }
    try {
      await _setupPeerConnection(
          peerId: effective.from, callType: effective.callType);
      final sdp = effective.sdp;
      if (sdp == null) throw StateError('Missing offer SDP');
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, effective.sdpType ?? 'offer'));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _sendSignal(CallSignal(
          type: CallSignalType.answer,
          from: myId,
          to: effective.from,
          callId: effective.callId,
          callType: effective.callType,
          payload: {'sdp': answer.sdp, 'type': answer.type}));
      // Store the answer on the calls row as well (future caller-side
      // fallback; the caller currently reads the answer over
      // Realtime). Fire-and-forget: it is not on the critical path.
      unawaited(
          _storeAnswerSdp(effective.callId, answer.sdp, answer.type));
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
    unawaited(_stopIncomingCallAlert());
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
        // Keep the offer so a callee who answered a call push can ask
        // for it to be re-sent (their Realtime offer never arrived).
        _outgoingOfferSdp = offer.sdp;
        _outgoingOfferType = offer.type;
        await _sendSignal(CallSignal(
            type: CallSignalType.offer,
            from: myId,
            to: calleeId,
            callId: callId,
            callType: callType,
            payload: {'sdp': offer.sdp, 'type': offer.type}));
        // Store the offer on the calls row as well: a callee whose
        // Realtime offer never arrived can fetch it with a plain
        // select on accept instead of waiting on the requestOffer
        // resend. Awaited (so the row has it before the callee can
        // answer) but best-effort — a failed store never breaks the
        // call, the Realtime offer is still the primary path.
        await _storeOfferSdp(callId, offer.sdp, offer.type);
        // Wake the callee if their app is closed or backgrounded: the
        // Realtime offer only reaches a connected client. Fix 8: the
        // push is AWAITED (bounded to 5s inside _sendCallPush) and its
        // result is surfaced on the call screen — when nothing was
        // sent, the caller sees why instead of ringing into the void.
        // The ring timer starts after the push returns, so the ring
        // window is not spent waiting on it. NOTE: a pre-ring check of
        // the callee's push_tokens row is not possible client-side —
        // the RLS SELECT policy is own-rows-only (migration 011) — so
        // the push result itself (sent: 0, reason: no_tokens) is the
        // authoritative "callee has no push registration" signal.
        callPushWarning.value = null;
        final pushResult = await _sendCallPush(
          calleeId: calleeId,
          callId: callId,
          callType: callType,
        );
        callPushWarning.value = callPushWarningMessage(pushResult);
      } catch (_) {
        await _closePeerConnection();
        await _updateCallRow('cancelled', end: true);
        _resetCall();
        rethrow;
      }
      // The callee may have answered over Realtime while the push was
      // awaited: only arm the ring timer while still outgoing.
      if (state.value == CallState.outgoing) {
        _armRingTimer(() async {
          // Nobody answered: mark it missed and end the outgoing screen.
          await _updateCallRow('missed', end: true);
          endReason = 'missed';
          await hangUp(sendSignal: true);
        });
      }
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
    // An answer for the current call, whether it is the first answer
    // (outgoing -> active) or a renegotiation answer after an ICE
    // restart (already active). Anything else is ignored.
    if (signal.callId != currentCallId) {
      return;
    }
    final isRenegotiation = state.value == CallState.active;
    if (state.value != CallState.outgoing && !isRenegotiation) {
      return;
    }
    final sdp = signal.sdp;
    if (sdp == null || _pc == null) {
      // A bad renegotiation answer must not hang up: the existing
      // connection may still recover, and the connection-state
      // handler ends the call if it does not.
      if (isRenegotiation) return;
      // An answer without usable SDP can never connect: end the call
      // instead of stranding the caller on "جارٍ الاتصال…".
      await hangUp(sendSignal: true);
      return;
    }
    try {
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, signal.sdpType ?? 'answer'));
      if (isRenegotiation) return;
      // Cancel the ring timer only after the answer proved usable (#6):
      // cancelling before setRemoteDescription stranded the caller when
      // a bad answer threw.
      _ringTimer?.cancel();
      await _updateCallRow('ongoing');
      _answered = true;
      state.value = CallState.active;
    } catch (_) {
      if (isRenegotiation) return;
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

  /// The callee asked for the offer again (they answered a call push
  /// whose SDP never arrived over Realtime). Re-sends the stored offer
  /// while this side is still ringing them; ignored otherwise.
  Future<void> _handleRequestOffer(CallSignal signal) async {
    if (state.value != CallState.outgoing ||
        signal.callId != currentCallId) {
      return;
    }
    final sdp = _outgoingOfferSdp;
    if (sdp == null) return;
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return;
    await _sendSignal(CallSignal(
        type: CallSignalType.offer,
        from: myId,
        to: signal.from,
        callId: signal.callId,
        callType: currentCallType ?? signal.callType,
        payload: {'sdp': sdp, 'type': _outgoingOfferType ?? 'offer'}));
  }

  /// The other side hung up. They already wrote the final history status,
  /// so this side only cleans up locally and ends its screen — but the
  /// peer's write is best-effort, so this side also finalizes the row
  /// when it is still open (see [_finalizeCallRowIfOpen]); the
  /// transition trigger rejects the write when the peer already
  /// finalized it, so this can never overwrite their final status.
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
    unawaited(_stopIncomingCallAlert());
    await _finalizeCallRowIfOpen(_answered ? 'completed' : 'missed');
    await _closePeerConnection();
    state.value = CallState.ended;
    _scheduleIdleReset();
    _clearCurrentCall();
  }

  /// The callee declined our outgoing call. They already marked the row
  /// declined; this side only ends its screen — but it also finalizes
  /// the row when it is still open, in case the callee's write failed.
  Future<void> _handleDecline(CallSignal signal) async {
    if (state.value != CallState.outgoing ||
        signal.callId != currentCallId) {
      return;
    }
    _ringTimer?.cancel();
    endReason = 'declined';
    unawaited(_stopIncomingCallAlert());
    await _finalizeCallRowIfOpen('declined');
    await _closePeerConnection();
    state.value = CallState.ended;
    _scheduleIdleReset();
    _clearCurrentCall();
  }

  /// Writes a terminal status only when the row is still open (not
  /// already terminal) and the transition is valid per migration 017.
  /// The peer usually finalizes the row first; this is the safety net
  /// for a failed or missing peer write on remote hangup / decline, so
  /// no end path leaves a row stuck at 'ringing' or 'ongoing' without
  /// `ended_at`. Best-effort: never throws. (The pg_cron job
  /// helba-mark-ringing-calls-missed is the server-side backstop.)
  Future<void> _finalizeCallRowIfOpen(String status) async {
    final rowId = currentCallRowId;
    if (rowId == null || _rowFinalized) return;
    try {
      final row = await _client
          .from('calls')
          .select('status')
          .eq('id', rowId)
          .maybeSingle();
      final current = row?['status']?.toString();
      if (current == null || current == status) return;
      if (!isValidCallTransition(current, status)) return;
      await _updateCallRow(status, end: true);
    } catch (_) {}
  }

  /// Asks the `send-call-push` Edge Function to wake the callee with a
  /// high-priority incoming-call push. The Realtime offer is the
  /// primary path, so a failure here (no function deployed yet, no
  /// network) never throws and never breaks the call. The app
  /// authenticates with its own Supabase session (JWT) — it never holds
  /// the trigger secret.
  ///
  /// Fix 8: this is NOT fire-and-forget any more. The result is
  /// returned (never thrown) so the caller can surface it: when the
  /// function answers `sent: 0` the callee was not woken, and the call
  /// screen warns the caller instead of ringing into the void. The
  /// invoke is bounded (5s) so a slow push cannot stall the call.
  Future<CallPushResult> _sendCallPush({
    required String calleeId,
    required String callId,
    required String callType,
  }) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) {
      return const CallPushResult(
        ok: false,
        sent: 0,
        failed: 0,
        reason: 'no_user',
      );
    }
    try {
      final response = await _client.functions
          .invoke(
            'send-call-push',
            body: buildCallPushBody(
              callId: callId,
              calleeId: calleeId,
              callerId: myId,
              callType: callType,
            ),
          )
          .timeout(const Duration(seconds: 5));
      return parseCallPushResult(response.data);
    } catch (_) {
      // Best-effort: the ringing call continues over Realtime.
      return const CallPushResult(
        ok: false,
        sent: 0,
        failed: 0,
        reason: 'request_failed',
      );
    }
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
    unawaited(_stopIncomingCallAlert());
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
      'video': video ? callVideoConstraints() : false,
    });
    _local = stream;
    localStream.value = stream;
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        ...turnIceServers,
      ],
      // STUN only until TURN entries are added to [turnIceServers]:
      // calls may fail on strict symmetric-NAT networks; that is a
      // known, honest limit.
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
    // Cap the video sender at 2.5 Mbps so a video call stays usable on
    // weak networks instead of sending unconstrained high-resolution
    // video. Best-effort: a platform that rejects the parameters must
    // not break the call.
    if (video) await _capVideoBitrate(pc);
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

  /// Caps the video sender bitrate at [callVideoMaxBitrate] (2.5 Mbps).
  /// Best-effort: any failure is swallowed so the call still proceeds
  /// without the cap.
  Future<void> _capVideoBitrate(RTCPeerConnection pc) async {
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        encodings[0].maxBitrate = callVideoMaxBitrate;
        await sender.setParameters(params);
      }
    } catch (_) {
      // Best-effort: the call works without the cap.
    }
  }

  void _onConnectionState(RTCPeerConnectionState connectionState) {
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _connectionTimer?.cancel();
      isReconnecting.value = false;
      return;
    }
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _connectionTimer?.cancel();
      _tryIceRestartOrEnd();
      return;
    }
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      // Brief drops recover on their own; give the connection time to
      // come back before restarting ICE, and show "reconnecting" so
      // the user knows the call is not dead.
      isReconnecting.value = true;
      _connectionTimer?.cancel();
      _connectionTimer = Timer(disconnectReconnectDelay, () {
        if ((state.value == CallState.active ||
                state.value == CallState.outgoing) &&
            _pc?.connectionState ==
                RTCPeerConnectionState
                    .RTCPeerConnectionStateDisconnected) {
          _tryIceRestartOrEnd();
        }
      });
    }
  }

  /// Attempts one ICE restart when the call is active or outgoing and
  /// no restart has been tried yet for this call; otherwise ends the
  /// call with a connection error. At most one restart per call.
  void _tryIceRestartOrEnd() {
    final isActiveCall =
        state.value == CallState.active || state.value == CallState.outgoing;
    if (shouldAttemptIceRestart(
        attempted: _iceRestartAttempted, isActiveCall: isActiveCall)) {
      unawaited(_restartIce().catchError((_) {}));
      return;
    }
    isReconnecting.value = false;
    unawaited(_endWithConnectionError().catchError((_) {}));
  }

  /// Restarts ICE for the current call (one attempt per call): fresh ICE
  /// gathering plus a re-offer for the same callId, which the peer
  /// answers as a renegotiation (see [_handleOffer]). On any failure
  /// the call ends with a connection error.
  Future<void> _restartIce() async {
    final pc = _pc;
    final callId = currentCallId;
    final peerId = currentPeerId;
    final callType = currentCallType;
    if (pc == null || callId == null || peerId == null || callType == null) {
      isReconnecting.value = false;
      await _endWithConnectionError();
      return;
    }
    _iceRestartAttempted = true;
    isReconnecting.value = true;
    try {
      // Canonical WebRTC ICE restart: the offer constraint alone
      // generates a fresh ufrag and new candidates; no separate
      // restartIce() call is needed (and calling both is redundant).
      final offer = await pc.createOffer(iceRestartOfferConstraints);
      await pc.setLocalDescription(offer);
      final myId = _client.auth.currentUser?.id;
      if (myId == null) throw StateError('No signed-in user');
      await _sendSignal(CallSignal(
          type: CallSignalType.offer,
          from: myId,
          to: peerId,
          callId: callId,
          callType: callType,
          payload: {'sdp': offer.sdp, 'type': offer.type}));
    } catch (_) {
      isReconnecting.value = false;
      await _endWithConnectionError();
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

  void _armRingTimer(Future<void> Function() onTimeout,
      {Duration? timeout}) {
    _ringTimer?.cancel();
    _ringTimer = Timer(timeout ?? callRingTimeout, () {
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

  /// Best-effort store of the offer SDP on the calls row (signalling
  /// fallback for a callee whose Realtime offer never arrived). Never
  /// throws; a failed store leaves the Realtime offer as the only
  /// route. The [callId] is the calls row id.
  Future<void> _storeOfferSdp(
      String callId, String? sdp, String? type) async {
    if (sdp == null || sdp.isEmpty) return;
    try {
      await _client.from('calls').update({
        'offer_sdp': sdp,
        'offer_sdp_type': type ?? 'offer',
      }).eq('id', callId);
    } catch (_) {}
  }

  /// Best-effort store of the answer SDP on the calls row (stored for
  /// a future caller-side fallback). Never throws.
  Future<void> _storeAnswerSdp(
      String callId, String? sdp, String? type) async {
    if (sdp == null || sdp.isEmpty) return;
    try {
      await _client.from('calls').update({
        'answer_sdp': sdp,
        'answer_sdp_type': type ?? 'answer',
      }).eq('id', callId);
    } catch (_) {}
  }

  void _resetCall() {
    _ringTimer?.cancel();
    _connectionTimer?.cancel();
    _pendingOverlayTimer?.cancel();
    _pendingIncomingCall = null;
    // A fresh call gets a fresh ICE-restart attempt and a clear
    // reconnecting indicator.
    _iceRestartAttempted = false;
    isReconnecting.value = false;
    // Safety net: any end path that forgot to stop the ringtone or clear
    // the tray notification is covered here.
    unawaited(_stopIncomingCallAlert());
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
    _outgoingOfferSdp = null;
    _outgoingOfferType = null;
    // A stale push warning must not survive into the next call (fix 8).
    callPushWarning.value = null;
    // A waiting accept must not hang when the call ends underneath it
    // (remote hangup while it waits for the re-sent offer).
    final completer = _pendingOfferCompleter;
    _pendingOfferCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('Call ended'));
    }
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
    // Capture the app navigator and messenger before acceptCall: the
    // dialog is popped by the incomingCall listener when acceptCall
    // clears it (success or failure), so nothing below may use this
    // dialog's context. The dialog stays open with a spinner while
    // acceptCall runs — a push-triggered accept may wait for the caller
    // to resend the offer, and the user must see that it is connecting
    // instead of staring at the inbox.
    final navigator = helbaNavigatorKey.currentState;
    final rootContext = helbaNavigatorKey.currentContext;
    final messenger = rootContext == null
        ? null
        : ScaffoldMessenger.of(rootContext);
    final accepted =
        await CallService.instance.acceptCall(widget.signal);
    // acceptCall clears incomingCall, which pops this dialog through
    // the listener; close it here only if it is still open.
    if (mounted) Navigator.of(context).pop();
    if (!accepted) {
      // Permission denied, or the offer never arrived (caller gone):
      // acceptCall already declined the call.
      messenger?.showSnackBar(
        const SnackBar(
            content: Text('تعذّر الرد على المكالمة. تحقق من الأذونات والاتصال.')),
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
          if (_busy)
            const Column(children: [
              CircularProgressIndicator(),
              SizedBox(height: 8),
              Text('جارٍ الاتصال…',
                  style: TextStyle(color: Colors.black54)),
            ])
          else
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              Column(children: [
                FloatingActionButton(
                  heroTag: 'decline_call',
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  onPressed: () {
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
                  onPressed: _accept,
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

  /// Banner shown while ringing when the call push did not reach the
  /// callee (fix 8): the caller sees why the other phone may not ring.
  /// Hidden once the push is confirmed delivered (or the call ends).
  /// Small "reconnecting" label shown while the connection is down and
  /// an ICE restart is being attempted. Hidden otherwise.
  Widget _reconnectingIndicator() {
    return ValueListenableBuilder<bool>(
      valueListenable: _service.isReconnecting,
      builder: (_, reconnecting, __) {
        if (!reconnecting) return const SizedBox.shrink();
        return const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('إعادة الاتصال…',
              style: TextStyle(fontSize: 14, color: Colors.amber)),
        );
      },
    );
  }

  Widget _callPushWarningBanner() {
    return ValueListenableBuilder<String?>(
      valueListenable: _service.callPushWarning,
      builder: (_, warning, __) {
        if (warning == null) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            margin: const EdgeInsets.only(top: 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade700,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              warning,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        );
      },
    );
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
                        _reconnectingIndicator(),
                        _callPushWarningBanner(),
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
                      _reconnectingIndicator(),
                      _callPushWarningBanner(),
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
