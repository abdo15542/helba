import 'dart:async';

import 'package:flutter/material.dart';
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
  bool _answered = false;
  bool _rowFinalized = false;
  bool _overlayShowing = false;

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
  }

  void _handleBroadcast(Map<String, dynamic> payload) {
    final signal = parseCallSignal(payload);
    if (signal == null) return;
    if (signal.to != _client.auth.currentUser?.id) return;
    switch (signal.type) {
      case CallSignalType.offer:
        _handleOffer(signal);
        break;
      case CallSignalType.answer:
        _handleAnswer(signal);
        break;
      case CallSignalType.ice:
        _handleIce(signal);
        break;
      case CallSignalType.hangup:
        _handleRemoteHangup(signal);
        break;
      case CallSignalType.decline:
        _handleDecline(signal);
        break;
    }
  }

  Future<void> _sendSignal(CallSignal signal) async {
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
  }

  // -- Incoming call ---------------------------------------------------------

  Future<void> _handleOffer(CallSignal signal) async {
    // Busy in another call: decline immediately so the caller is not left
    // ringing, and never overwrite the call already in progress.
    if (state.value != CallState.idle) {
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
    incomingCall.value = signal;
    incomingCallerName.value = null;
    state.value = CallState.incoming;
    _loadCallerName(signal.from);
    _armRingTimer(() async {
      // Unanswered: the callee marks it missed, then dismisses the overlay.
      await _updateCallRow('missed', end: true);
      endReason = 'missed';
      incomingCall.value = null;
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
    if (context == null || _overlayShowing) return;
    _overlayShowing = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => IncomingCallDialog(signal: signal),
    ).then((_) => _overlayShowing = false);
  }

  /// Accepts a ringing incoming call. Returns false when the microphone
  /// (or camera, for video) permission is denied — the call is declined
  /// automatically in that case. On success the caller opens [CallPage].
  Future<bool> acceptCall(CallSignal signal) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return false;
    _ringTimer?.cancel();
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
    if (myId == null || state.value != CallState.idle) return null;
    final video = callType == 'video';
    if (!await _ensurePermissions(video: video)) return null;
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
    state.value = CallState.outgoing;
    _armRingTimer(() async {
      // Nobody answered: mark it missed and end the outgoing screen.
      await _updateCallRow('missed', end: true);
      endReason = 'missed';
      await hangUp(sendSignal: true);
    });
    return callId;
  }

  // -- Remote signals --------------------------------------------------------

  Future<void> _handleAnswer(CallSignal signal) async {
    if (state.value != CallState.outgoing ||
        signal.callId != currentCallId) {
      return;
    }
    _ringTimer?.cancel();
    final sdp = signal.sdp;
    if (sdp == null || _pc == null) return;
    try {
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, signal.sdpType ?? 'answer'));
      await _updateCallRow('ongoing');
      _answered = true;
      state.value = CallState.active;
    } catch (_) {
      // A bad answer leaves the call ringing until the ring timer ends it.
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
    endReason = 'ended';
    incomingCall.value = null;
    await _closePeerConnection();
    state.value = CallState.ended;
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
    _clearCurrentCall();
  }

  // -- Ending a call -----------------------------------------------------------

  /// Ends the current call: tells the peer, closes the peer connection,
  /// writes the final history status (completed when answered, cancelled
  /// when it never was) and moves the state to ended so the call screen
  /// pops itself.
  Future<void> hangUp({bool sendSignal = true}) async {
    _ringTimer?.cancel();
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
    _clearCurrentCall();
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
    isSpeakerOn.value = on;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
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
      'audio': true,
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
    await pc.addStream(stream);
    // Voice calls default to the earpiece, video calls to the speaker.
    isSpeakerOn.value = video;
    try {
      await Helper.setSpeakerphoneOn(video);
    } catch (_) {}
    isMuted.value = false;
    isCameraOff.value = false;
  }

  Future<void> _closePeerConnection() async {
    final pc = _pc;
    _pc = null;
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
  }

  void _armRingTimer(Future<void> Function() onTimeout) {
    _ringTimer?.cancel();
    _ringTimer = Timer(callRingTimeout, () {
      unawaited(onTimeout());
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
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _activeSince;

  CallService get _service => CallService.instance;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
    _service.localStream.addListener(_updateRenderers);
    _service.remoteStream.addListener(_updateRenderers);
    _service.state.addListener(_onStateChanged);
    _updateRenderers();
    _onStateChanged();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_activeSince != null && mounted) {
        setState(
            () => _elapsed = DateTime.now().difference(_activeSince!));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.localStream.removeListener(_updateRenderers);
    _service.remoteStream.removeListener(_updateRenderers);
    _service.state.removeListener(_onStateChanged);
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _updateRenderers() {
    final local = _service.localStream.value;
    if (local != null && _localRenderer.srcObject != local) {
      _localRenderer.srcObject = local;
    }
    final remote = _service.remoteStream.value;
    if (remote != null && _remoteRenderer.srcObject != remote) {
      _remoteRenderer.srcObject = remote;
    }
  }

  void _onStateChanged() {
    final state = _service.state.value;
    if (state == CallState.active && _activeSince == null) {
      _activeSince = DateTime.now();
    }
    if (state == CallState.ended && mounted) {
      // Let the next frame finish, then leave the call screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
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
                          ? 'انتهت المكالمة'
                          : 'مكالمة';
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
