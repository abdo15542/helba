import 'dart:async';
import 'dart:io' as io;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player_advanced/flutter_ringtone_player_advanced.dart';

import 'src/auth.dart';
import 'src/calls.dart';
import 'src/network.dart';
import 'src/push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Closed-app incoming calls must ring: register the background FCM
  // handler BEFORE runApp, so a call push wakes the app even when it
  // is terminated. The handler (below) shows the full-screen
  // incoming-call notification and starts the looping ringtone in a
  // background isolate.
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  // Route Supabase traffic through the DNS-over-HTTPS fallback so the app
  // keeps working on networks whose system DNS cannot resolve Supabase.
  io.HttpOverrides.global = HelbaHttpOverrides();
  // M27: first paint must not wait for the system-proxy lookup, and a
  // failure there must not prevent startup. Run the app immediately and
  // load the proxy concurrently; the proxy logic itself is unchanged,
  // and clients created after it loads pick it up.
  runApp(const HelbaApp());
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());
  unawaited(_loadProxyInBackground());
}

/// Background FCM message handler: runs in a background isolate when a
/// push arrives while the app is closed or backgrounded. Must be a
/// top-level function (see [FirebaseMessaging.onBackgroundMessage]) and
/// is registered in [main] before runApp.
///
/// Before this handler there was none, so a closed-app call push only
/// produced the system's plain notification (one ding, no ring, no
/// answer button) — the looping ringtone only started in the in-app
/// overlay, which never runs when the app is closed. This handler
/// makes a closed-app call ring:
///
/// * an incoming call (`data.type == 'call'`, see [parseCallPushData])
///   shows the full-screen incoming-call notification on the
///   `helba_calls` channel (Answer / Decline actions, payload = the
///   encoded call, so tapping Answer opens the app into the
///   incoming-call flow — see [incomingCallNotificationDetails]) and
///   starts the looping system ringtone;
/// * a non-call message is ignored: the FCM notification block already
///   shows a system notification for it, and a local banner would
///   double-notify.
///
/// The ringtone stops when the call is answered / declined / ends (the
/// main isolate's CallService stops it — see
/// [CallRingtone.stopAny]) or after the ring window ([callRingTimeout],
/// 60s), so it never loops forever if the user ignores the call. The
/// notification is cancelled at the same time. Best-effort throughout:
/// a failure here must never crash the isolate. The channel sound
/// (bundled ringtone, see [helbaCallsChannel]) is the fallback when
/// the ringtone player is unavailable in this isolate.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(
    RemoteMessage message) async {
  final call = parseCallPushData(message.data);
  if (call == null) return;
  // The background isolate needs its own Firebase app, with the same
  // explicit options as the main isolate (see [helbaFirebaseOptions]).
  // firebase_messaging may already have initialised it; only
  // initialise when nothing is registered yet.
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: helbaFirebaseOptions);
    }
  } catch (_) {
    // Initialisation failed: the notification below is best-effort.
  }
  final plugin = FlutterLocalNotificationsPlugin();
  try {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    // Make sure the helba_calls channel exists (with its ringtone
    // sound) even if the app was never opened after install: creating
    // an existing channel is a no-op. Taps are handled by the main
    // isolate's response handler (set up in _setupLocalNotifications
    // when the app runs), so no response callback is needed here.
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(helbaCallsChannel);
    await plugin.show(
      id: stableNotificationId(call.callId),
      title: call.callerName ?? 'هلبة',
      body: call.callType == 'video'
          ? 'مكالمة فيديو واردة'
          : 'مكالمة صوتية واردة',
      notificationDetails: NotificationDetails(
        android: incomingCallNotificationDetails(),
      ),
      payload: encodeCallPushPayload(call),
    );
  } catch (e) {
    debugPrint('Helba push: background call notification failed: $e');
  }
  // The looping system ringtone. The channel sound above plays the
  // bundled chime once when the notification posts; this loop is what
  // keeps ringing until the user answers / declines. Fire-and-forget:
  // a slow or unavailable player must not delay the handler.
  unawaited(FlutterRingtonePlayer()
      .playRingtone(looping: true)
      .catchError((_) {}));
  Timer(callRingTimeout, () {
    unawaited(FlutterRingtonePlayer().stop().catchError((_) {}));
    unawaited(plugin
        .cancel(id: stableNotificationId(call.callId))
        .catchError((_) {}));
  });
}

/// Loads the system proxy off the startup path. Any failure is swallowed
/// here because the app must still start (direct connection) without it.
Future<void> _loadProxyInBackground() async {
  try {
    await loadSystemProxy();
  } catch (_) {
    // No proxy: the app continues with a direct connection.
  }
}

/// Closes the shared DNS-over-HTTPS client when the app process is
/// detached, so it is not left open for the lifetime of the process
/// (network.dart's closeDohClient(); the client is recreated lazily).
class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) closeDohClient();
  }
}
