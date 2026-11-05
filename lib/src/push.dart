import 'dart:async';
import 'dart:io' as io;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'deeplink.dart';

// ---------------------------------------------------------------------------
// Push notifications (Feature 5).
//
// BUILD FACT — READ FIRST: the Firebase project "Helba" (helba-379fd,
// created 2026-11-05) is wired in here with explicit FirebaseOptions, so
// the app needs neither a google-services.json file nor the google-services
// Gradle plugin. The four option values are public client identifiers
// (the same kind as the Supabase publishable key already in the codebase),
// not secrets. setupPushNotifications() still wraps Firebase.initializeApp()
// and every FirebaseMessaging access in try/catch: if initialisation fails
// for any reason the push feature silently stays disabled — the app never
// crashes, and analyze / tests / the CI release build are unaffected (the
// plugins compile from Maven artifacts). Push still needs the
// send-message-push Edge Function deployed with its secrets (see
// supabase/functions/send-message-push/README.md) before any notification
// actually arrives.
//
// DEVICE ADDRESS: firebase_messaging 17 replaced FCM registration tokens
// with the Firebase Installation ID (FID) as the direct-send target
// (`register()` + `onRegistered`). The FID is what the app stores in
// `push_tokens.token`, and the Edge Function sends to it with the FCM
// HTTP v1 `message.fid` field (the `token` field is deprecated and also
// accepts an FID during the transition, but `fid` is the current API).
// ---------------------------------------------------------------------------

/// Android notification channel for incoming chat messages.
const pushMessagesChannelId = 'helba_messages';

/// Maximum characters of a message body shown in a notification preview.
const pushPreviewMaxLength = 100;

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart). No Firebase here.
// ---------------------------------------------------------------------------

/// Parses a `helba://chat/<conversation_id>` deep link. Returns the
/// conversation id, or null for anything else: auth links, other schemes,
/// an empty id, or more than one path segment.
String? parseChatDeepLink(Uri uri) {
  if (!isChatDeepLink(uri)) return null;
  return chatIdFromDeepLink(uri);
}

/// The title shown on a message notification: the sender's display name,
/// falling back to the app name when it is missing or blank.
String buildNotificationTitle(String? senderName) {
  final name = senderName?.trim() ?? '';
  return name.isEmpty ? 'هلبة' : name;
}

/// The body shown on a message notification: a ~100-character preview of
/// a text message, or an Arabic label for attachments. An empty text body
/// falls back to 'رسالة جديدة' rather than an empty notification.
String buildNotificationBody(String? body, String? messageType) {
  switch (messageType) {
    case 'image':
      return 'صورة';
    case 'video':
      return 'فيديو';
    case 'audio':
      return 'ملف صوتي';
    case 'file':
      return 'ملف';
    default:
      break;
  }
  final text = body?.trim() ?? '';
  if (text.isEmpty) return 'رسالة جديدة';
  if (text.length <= pushPreviewMaxLength) return text;
  return '${text.substring(0, pushPreviewMaxLength)}…';
}

/// True when [token] looks like a usable device address (an FID): a
/// non-empty, non-blank string. Anything else is never sent to the server.
bool isValidPushToken(String? token) =>
    token != null && token.trim().isNotEmpty;

// ---------------------------------------------------------------------------
// Setup: Firebase + local notifications + token registration.
// ---------------------------------------------------------------------------

final _localNotifications = FlutterLocalNotificationsPlugin();
bool _pushSetupDone = false;
StreamSubscription<String>? _registeredSubscription;
StreamSubscription<RemoteMessage>? _onMessageSubscription;
StreamSubscription<RemoteMessage>? _onMessageOpenedSubscription;

/// Registers this device for push notifications and wires foreground /
/// tap handling. Idempotent: safe to call on every sign-in / rebuild.
///
/// Called from AuthGate once a confirmed signed-in user is present (same
/// place CallService.startListening() is called). Never throws: if
/// Firebase is not configured (no google-services.json yet) the whole
/// feature silently stays disabled and the app works exactly as before.
Future<void> setupPushNotifications() async {
  if (_pushSetupDone) return;
  _pushSetupDone = true;
  try {
    // Firebase project "Helba" (helba-379fd), created 2026-11-05. The app
    // passes its client config explicitly, so it needs neither a
    // google-services.json file nor the google-services Gradle plugin.
    // These four values are public client identifiers, not secrets. If
    // initialisation still fails for any reason, push stays disabled and
    // nothing else breaks.
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'AIzaSyBsJf8p3BHjQCJHU9PkFmPy87DFScWJr3k',
        appId: '1:1097242039750:android:d9b1cfae293fad3a3e0ec7',
        messagingSenderId: '1097242039750',
        projectId: 'helba-379fd',
      ),
    );
  } catch (_) {
    return;
  }
  try {
    await _setupLocalNotifications();
    await _requestNotificationPermission();
    // Subscribe before registering: register() completes the FID
    // registration and onRegistered then delivers the FID to store.
    final messaging = FirebaseMessaging.instance;
    _registeredSubscription ??=
        messaging.onRegistered.listen((fid) {
      unawaited(_upsertPushToken(fid));
    });
    await messaging.register();
    _onMessageSubscription ??=
        FirebaseMessaging.onMessage.listen(_showForegroundMessage);
    _onMessageOpenedSubscription ??= FirebaseMessaging.onMessageOpenedApp
        .listen((message) => _openChatFromMessage(message));
    final initial = await messaging.getInitialMessage();
    if (initial != null) _openChatFromMessage(initial);
  } catch (_) {
    // Any later failure (permissions, registration, listeners) also just
    // disables push; the app must never crash over notifications.
    return;
  }
}

Future<void> _setupLocalNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await _localNotifications.initialize(
    settings: settings,
    onDidReceiveNotificationResponse: (response) {
      final conversationId = response.payload?.trim() ?? '';
      if (conversationId.isNotEmpty) {
        pendingChatId.value = conversationId;
      }
    },
  );
  final android = _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      pushMessagesChannelId,
      'رسائل هلبة',
      description: 'إشعارات الرسائل الجديدة',
      importance: Importance.high,
    ),
  );
}

Future<void> _requestNotificationPermission() async {
  try {
    await FirebaseMessaging.instance.requestPermission();
  } catch (_) {
    // FCM permission is best-effort; the local-notification permission
    // below is what actually gates the banner on Android 13+.
  }
  if (io.Platform.isAndroid) {
    try {
      await Permission.notification.request();
    } catch (_) {
      // A denied notification permission just means no banners; the app
      // still works, and the user can enable it later from settings.
    }
  }
}

/// Stores [fid] (this install's Firebase Installation ID) for the
/// current user (insert or refresh updated_at on conflict). Best-effort:
/// a failed upsert never throws.
Future<void> _upsertPushToken(String fid) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null || !isValidPushToken(fid)) return;
  try {
    await Supabase.instance.client.from('push_tokens').upsert(
      {
        'user_id': userId,
        'token': fid.trim(),
        'platform': 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'user_id,token',
    );
  } catch (_) {
    // The token table (migration 011) may not be applied yet; push just
    // does not register until it is.
  }
}

/// Shows a foreground FCM message as a local notification. The Edge
/// Function already sends title = sender name and body = preview, so the
/// notification fields are used as-is; the data payload is only trusted
/// for the conversation id (re-parsed through the chat deep-link rules).
Future<void> _showForegroundMessage(RemoteMessage message) async {
  try {
    final data = message.data;
    final conversationId = data['conversation_id']?.toString().trim() ?? '';
    if (conversationId.isEmpty) return;
    final title = buildNotificationTitle(message.notification?.title);
    final body = buildNotificationBody(
      message.notification?.body ?? data['body']?.toString(),
      data['message_type']?.toString(),
    );
    await _localNotifications.show(
      id: conversationId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          pushMessagesChannelId,
          'رسائل هلبة',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: conversationId,
    );
  } catch (_) {
    // A failed banner must never crash the app.
  }
}

/// A notification tap (or a cold start from one) opens the chat. This
/// only sets pendingChatId; AuthGate owns the actual navigation (see
/// auth.dart), so the tap path and the `helba://chat/<id>` link share one
/// navigation handler.
void _openChatFromMessage(RemoteMessage message) {
  final conversationId =
      message.data['conversation_id']?.toString().trim() ?? '';
  if (conversationId.isNotEmpty) pendingChatId.value = conversationId;
}
