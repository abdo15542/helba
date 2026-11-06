import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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
//
// DIRECT-FID-FETCH VERDICT (finding #15, verified in the plugin source,
// firebase_messaging 17.0.1 + firebase_messaging_platform_interface
// 4.11.1): there is NO way to fetch the current FID directly with the
// dependencies already in pubspec.yaml. `FirebaseMessaging.getToken()`
// is deprecated and returns the legacy FCM registration token
// (method_channel_messaging.dart invokes 'Messaging#getToken' and
// returns `data['token']`) — NOT the Installation ID — so it must NOT
// be misused as an FID. The only FID source is the `onRegistered`
// broadcast stream, whose controller is a plain broadcast
// StreamController with no replay: an FID posted before the Dart
// listener attaches is dropped. A true direct fetch needs the
// firebase_installations package (`FirebaseInstallations.instance.getId()`),
// which requires a pubspec.yaml change the coordinator must approve —
// pubspec.yaml is off-limits to this fix. What this file DOES do instead:
// (a) `_pushSetupDone` is set only after successful registration and
// reset on any failure, so setup is safely re-callable; (b) a re-entry
// with no FID yet re-attaches the listener and re-calls `register()`;
// (c) every FID upsert is retried with backoff and re-run on the next
// sign-in via [retryPushTokenUpsert].
// ---------------------------------------------------------------------------

/// Android notification channel for incoming chat messages.
const pushMessagesChannelId = 'helba_messages';

/// Android notification channel for incoming calls. Max importance with
/// sound, so a call push wakes the user even when the app is closed.
/// The `send-call-push` Edge Function sends on this channel id.
const pushCallsChannelId = 'helba_calls';

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

/// Local copy of the UUID check (finding F7/F8, push side): a
/// conversation id from an FCM payload or a notification tap is only
/// trusted for [pendingChatId] when it is a well-formed UUID. This is
/// deliberately a duplicate of the one-line regex in utils.isValidUuid
/// (same pattern) rather than an import, so the push and chat agents do
/// not edit the same shared file.
bool isValidPushConversationId(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value.trim());

/// Stable notification id for a conversation (finding #17): FNV-1a
/// 32-bit over the conversation id's code units, masked to a positive
/// int. Unlike `String.hashCode` it is deterministic across processes
/// and restarts, so one conversation's banner cannot silently replace
/// another's after a restart, and two conversations do not collide
/// merely because their hashCodes happened to match.
int stableNotificationId(String conversationId) {
  var hash = 0x811c9dc5;
  for (final unit in conversationId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

// ---------------------------------------------------------------------------
// Incoming-call push (see lib/src/calls.dart for the call flow).
// ---------------------------------------------------------------------------

/// An incoming call announced by a push: the FCM data payload of a
/// `send-call-push` message, or the payload of a local call notification
/// tap. Carries no SDP — the offer arrives over Realtime, or is
/// re-requested on accept (see CallService.acceptCall).
class CallPushPayload {
  final String callId;
  final String callerId;
  final String? callerName;
  final String callType;

  const CallPushPayload({
    required this.callId,
    required this.callerId,
    this.callerName,
    this.callType = 'voice',
  });

  Map<String, dynamic> toJson() => {
        'type': 'call',
        'call_id': callId,
        'caller_id': callerId,
        if (callerName != null) 'caller_name': callerName,
        'call_type': callType,
      };
}

/// Parses an FCM data payload into a call payload, or null when it is
/// not an incoming-call message (any other `type`, or a missing /
/// malformed call id / caller id). The ids must be well-formed UUIDs:
/// a tap or a forged payload must never queue a call the database does
/// not have. Pure (no Firebase): unit-tested.
CallPushPayload? parseCallPushData(Map<String, dynamic> data) {
  if (data['type']?.toString() != 'call') return null;
  final callId = data['call_id']?.toString().trim() ?? '';
  final callerId = data['caller_id']?.toString().trim() ?? '';
  if (!isValidPushConversationId(callId)) return null;
  if (!isValidPushConversationId(callerId)) return null;
  final name = data['caller_name']?.toString().trim();
  final type = data['call_type']?.toString() == 'video' ? 'video' : 'voice';
  return CallPushPayload(
    callId: callId,
    callerId: callerId,
    callerName: name?.isNotEmpty == true ? name : null,
    callType: type,
  );
}

/// Encodes a call payload as the `payload` string of a local
/// notification, so a tap can reconstruct it. JSON, so a caller name
/// containing any separator survives.
String encodeCallPushPayload(CallPushPayload payload) =>
    jsonEncode(payload.toJson());

/// Decodes a local-notification payload string into a call payload, or
/// null when it is not one (e.g. a chat payload, which is a bare
/// conversation id). Pure: unit-tested.
CallPushPayload? decodeCallPushPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) return null;
    return parseCallPushData(decoded);
  } catch (_) {
    return null;
  }
}

/// An incoming call announced by a push, waiting to be handled: set when
/// an FCM call message arrives (foreground) or is tapped (background /
/// cold start). CallService observes this (see startListening) and runs
/// the incoming-call flow once the user is signed in, then clears it.
/// Same pattern as [pendingChatId]: a ValueNotifier so either entry
/// point can set it without a BuildContext.
final ValueNotifier<CallPushPayload?> pendingIncomingCallPush =
    ValueNotifier(null);

/// True while CallService is showing a ringing incoming call. Push.dart
/// reads it (never writes it except for this initial false) to avoid
/// showing a second, duplicate call notification for a call the in-app
/// overlay already announces.
final ValueNotifier<bool> callRinging = ValueNotifier(false);

// ---------------------------------------------------------------------------
// Setup: Firebase + local notifications + token registration.
// ---------------------------------------------------------------------------

final _localNotifications = FlutterLocalNotificationsPlugin();

/// True only once [setupPushNotifications] has completed a successful
/// registration (finding #15). It is deliberately NOT set before
/// `Firebase.initializeApp()` any more, and it is reset to false in
/// every catch path, so a failed setup is re-callable instead of a
/// permanent no-op for the rest of the process. A re-entry while this
/// is true but no FID has arrived yet re-runs `register()` (see below).
bool _pushSetupDone = false;

/// True once `Firebase.initializeApp()` has succeeded; initialisation
/// itself is only attempted once per process.
bool _firebaseInitialized = false;

/// The FID received from `onRegistered`, kept in memory (finding #18,
/// app side): [deletePushTokenOnSignOut] needs it to prune the device's
/// `push_tokens` row, and [retryPushTokenUpsert] needs it to re-run a
/// failed upsert on the next sign-in.
String? _currentFid;

/// An FID whose upsert has not succeeded yet (after all retries), kept
/// so [retryPushTokenUpsert] can re-run it on the next sign-in or
/// connectivity regain (finding #16).
String? _pendingFid;

/// The conversation currently open on screen, if any (finding #20).
/// ChatPage sets `currentOpenConversationId.value = <its id>` when it
/// opens and `null` when it closes; push.dart only reads it, never
/// writes it except for this initial null. Until the chat agent wires
/// it, foreground banners for the open chat are not suppressed — the
/// own-message suppression below works regardless.
final ValueNotifier<String?> currentOpenConversationId = ValueNotifier(null);

/// True when the notification permission is permanently denied
/// (finding #19). The UI layer observes this and shows a one-time
/// prompt directing the user to app settings (via
/// [openAppNotificationSettings]); push.dart has no BuildContext, so
/// it exposes state instead of showing a dialog itself.
final ValueNotifier<bool> pushNotificationsPermanentlyDenied =
    ValueNotifier(false);

/// Warning shown to the user when push registration could not be
/// verified (fix 9): the FCM Installation ID never arrived via
/// `onRegistered`, or its `push_tokens` upsert kept failing. Without a
/// registered FID this device receives no call/message push while the
/// app is closed — and the old code failed silently, so the user only
/// discovered it when a call never rang. Null when registration is
/// verified (or not yet checked). The inbox observes this and shows a
/// one-time prompt with a retry action. push.dart has no BuildContext,
/// so it exposes state instead of showing a dialog itself.
final ValueNotifier<String?> pushRegistrationWarning = ValueNotifier(null);

/// The FID currently registered for this device, if one has arrived.
/// Exposed for diagnostics and for the sign-out pruning path.
String? get currentPushToken => _currentFid;

/// Whether push setup has completed a successful registration.
bool get pushSetupComplete => _pushSetupDone;

/// True once the current FID has been confirmed stored in `push_tokens`
/// (fix 9). The FID arriving via `onRegistered` is not enough: the
/// upsert can still fail (network / RLS), leaving the device
/// unregistered with no visible error. Reset to false whenever a new
/// FID arrives, so [_verifyPushRegistration] waits for the upsert too.
bool _pushTokenUpsertConfirmed = false;

StreamSubscription<String>? _registeredSubscription;
StreamSubscription<String>? _unregisteredSubscription;
StreamSubscription<RemoteMessage>? _onMessageSubscription;
StreamSubscription<RemoteMessage>? _onMessageOpenedSubscription;

/// Registers this device for push notifications and wires foreground /
/// tap handling. Idempotent: safe to call on every sign-in / rebuild.
///
/// Called from AuthGate once a confirmed signed-in user is present (same
/// place CallService.startListening() is called). Never throws: if
/// Firebase is not configured the whole feature silently stays disabled
/// and the app works exactly as before.
///
/// Re-callable by design (finding #15): a failed setup resets
/// `_pushSetupDone`, so the next sign-in retries it; a completed setup
/// whose FID never arrived (the `onRegistered` broadcast was posted
/// before the Dart listener attached) re-runs `register()` on re-entry
/// to trigger the event again; a completed setup with a known FID
/// retries any pending token upsert via [retryPushTokenUpsert].
Future<void> setupPushNotifications() async {
  if (_pushSetupDone) {
    if (_currentFid != null) {
      // Already registered with a known FID: only a failed upsert may
      // still be pending — retry it (finding #16).
      await retryPushTokenUpsert();
      return;
    }
    // Registered, but the FID never arrived via onRegistered (stream
    // race, finding #15): fall through and re-register to trigger the
    // event again. There is no direct FID fetch in firebase_messaging
    // 17 (see the verdict in the file header), so re-registration is
    // the only available replay mechanism.
    debugPrint('Helba push: setup done but no FID arrived; re-registering');
    _pushSetupDone = false;
  }
  try {
    if (!_firebaseInitialized) {
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
      _firebaseInitialized = true;
    }
  } catch (e) {
    debugPrint('Helba push: Firebase.initializeApp failed: $e');
    _pushSetupDone = false;
    return;
  }
  try {
    await _setupLocalNotifications();
    await _requestNotificationPermission();
    // Subscribe before registering: register() completes the FID
    // registration and onRegistered then delivers the FID to store.
    final messaging = FirebaseMessaging.instance;
    _registeredSubscription ??= messaging.onRegistered.listen(
      (fid) {
        _currentFid = fid;
        // A new FID is unconfirmed until its upsert lands (fix 9).
        _pushTokenUpsertConfirmed = false;
        unawaited(_upsertPushToken(fid));
      },
      onError: (Object e) {
        debugPrint('Helba push: onRegistered stream error: $e');
      },
    );
    _unregisteredSubscription ??= messaging.onUnregistered.listen(
      (fid) {
        // This install is no longer registered: forget the FID so the
        // next setup re-registers instead of trusting a stale token.
        if (_currentFid == fid) _currentFid = null;
        _pushTokenUpsertConfirmed = false;
        _pushSetupDone = false;
        debugPrint('Helba push: unregistered (FID $fid no longer active)');
      },
      onError: (Object e) {
        debugPrint('Helba push: onUnregistered stream error: $e');
      },
    );
    await messaging.register();
    _onMessageSubscription ??=
        FirebaseMessaging.onMessage.listen(_showForegroundMessage);
    _onMessageOpenedSubscription ??= FirebaseMessaging.onMessageOpenedApp
        .listen((message) => _openChatFromMessage(message));
    final initial = await messaging.getInitialMessage();
    if (initial != null) _openChatFromMessage(initial);
    // Only now — after successful registration — is setup "done".
    _pushSetupDone = true;
    // If the FID already arrived synchronously via the stream, make
    // sure its upsert is (re-)attempted even if the listener's
    // unawaited call raced with this return.
    await retryPushTokenUpsert();
    // Fix 9: verify the registration actually landed (FID arrived AND
    // its push_tokens upsert confirmed) instead of assuming it. Runs
    // in the background: a missing FID or a failed upsert sets
    // [pushRegistrationWarning] so the user sees it instead of
    // silently missing every closed-app call and message.
    // Re-registration on every launch is already guaranteed: the
    // setup flags are per-process, so a fresh launch (including after
    // a reinstall, which changes the FID) always runs register() again
    // and replaces the stale token.
    unawaited(_verifyPushRegistration());
  } catch (e) {
    // Any later failure (permissions, registration, listeners) also just
    // disables push; the app must never crash over notifications. Reset
    // the flag so the next sign-in / app resume retries (finding #15).
    debugPrint('Helba push: setup failed: $e');
    _pushSetupDone = false;
    return;
  }
}

/// Verifies (fix 9) that this launch actually registered a push token:
/// waits up to 20s for the FID to arrive via `onRegistered` AND for its
/// `push_tokens` upsert to be confirmed. If either never happens, sets
/// [pushRegistrationWarning] so the user sees it instead of silently
/// missing every closed-app call and message. Never throws; the app
/// works without push. A later successful upsert clears the warning
/// (see [_upsertPushToken]).
Future<void> _verifyPushRegistration() async {
  const deadline = Duration(seconds: 20);
  const pollEvery = Duration(seconds: 1);
  final started = DateTime.now();
  while (DateTime.now().difference(started) < deadline) {
    if (_currentFid != null && _pushTokenUpsertConfirmed) {
      pushRegistrationWarning.value = null;
      return;
    }
    await Future.delayed(pollEvery);
  }
  if (_currentFid == null) {
    debugPrint(
      'Helba push: no FID arrived within 20s; registration unverified',
    );
  } else {
    debugPrint(
      'Helba push: FID arrived but its push_tokens upsert was not '
      'confirmed within 20s',
    );
  }
  pushRegistrationWarning.value =
      'تعذّر تسجيل الإشعارات على هذا الجهاز — لن تصلك المكالمات والرسائل والهاتف مغلق. تحقق من الاتصال ثم أعد فتح التطبيق.';
}

/// Re-runs the push-token upsert for the FID we already have, if any
/// (finding #16). Safe to call from the auth layer on every successful
/// sign-in and on connectivity regain: it is a no-op when there is no
/// FID, no signed-in user, or nothing pending. Never throws.
Future<void> retryPushTokenUpsert() async {
  final fid = _pendingFid ?? _currentFid;
  if (fid == null || !isValidPushToken(fid)) return;
  if (Supabase.instance.client.auth.currentUser == null) return;
  await _upsertPushToken(fid);
}

/// Deletes this device's `push_tokens` row on sign-out (finding #18,
/// app side) so a signed-out device stops receiving the previous user's
/// notifications. Best-effort: never throws, never blocks sign-out.
/// The AUTH agent must call this BEFORE `auth.signOut()` (auth.dart
/// owns every sign-out call site; push.dart cannot hook it itself).
/// NOTE: the delete only succeeds if a `push_tokens` DELETE RLS policy
/// allows the user to delete their own row — that policy is another
/// coordinator's job. If it is missing, the delete fails silently here
/// (logged) and the stale row remains; that is recorded, not faked.
Future<void> deletePushTokenOnSignOut() async {
  final fid = _currentFid;
  if (fid == null || !isValidPushToken(fid)) return;
  try {
    await Supabase.instance.client
        .from('push_tokens')
        .delete()
        .eq('token', fid.trim());
    _currentFid = null;
    _pendingFid = null;
  } catch (e) {
    // Best-effort: keep _currentFid so a later sign-out (or a retry)
    // can try again. If the DELETE RLS policy is missing this will
    // fail every time — see the note above.
    debugPrint('Helba push: failed to delete push token on sign-out: $e');
  }
}

/// Opens the OS app-settings screen so the user can re-enable
/// notifications after a permanent denial (finding #19). Call it from
/// the UI prompt that observes [pushNotificationsPermanentlyDenied].
/// Never throws; clears the flag optimistically (the next setup run
/// re-checks the real permission state).
Future<void> openAppNotificationSettings() async {
  try {
    await openAppSettings();
    pushNotificationsPermanentlyDenied.value = false;
  } catch (e) {
    debugPrint('Helba push: openAppSettings failed: $e');
  }
}

Future<void> _setupLocalNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await _localNotifications.initialize(
    settings: settings,
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload?.trim() ?? '';
      final call = decodeCallPushPayload(payload);
      if (call != null) {
        // Tapping an incoming-call notification opens the app to the
        // incoming call screen (CallService handles it, like a push).
        pendingIncomingCallPush.value = call;
        return;
      }
      final conversationId = payload;
      if (isValidPushConversationId(conversationId)) {
        pendingChatId.value = conversationId;
      } else if (conversationId.isNotEmpty) {
        debugPrint(
          'Helba push: ignoring notification tap with invalid '
          'conversation id',
        );
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
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      pushCallsChannelId,
      'مكالمات هلبة',
      description: 'إشعارات المكالمات الواردة',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ),
  );
}

/// Cancels the tray notification for an incoming call (by call id).
/// Called when the in-app overlay takes over, and on every end path, so
/// a ringing notification never lingers after the call. Best-effort:
/// never throws.
Future<void> cancelCallNotification(String callId) async {
  try {
    await _localNotifications.cancel(id: stableNotificationId(callId));
  } catch (_) {}
}

/// Requests notification permission and records the outcome (finding
/// #19): the old code ignored the result entirely, so a permanently
/// denied permission left push silently dead with no guidance and no
/// log. A permanent denial sets [pushNotificationsPermanentlyDenied]
/// so the UI can show a one-time "enable from settings" prompt.
Future<void> _requestNotificationPermission() async {
  try {
    final settings = await FirebaseMessaging.instance.requestPermission();
    debugPrint(
      'Helba push: FCM authorizationStatus='
      '${settings.authorizationStatus}',
    );
  } catch (e) {
    // FCM permission is best-effort; the local-notification permission
    // below is what actually gates the banner on Android 13+.
    debugPrint('Helba push: FCM requestPermission failed: $e');
  }
  if (io.Platform.isAndroid) {
    try {
      final status = await Permission.notification.request();
      debugPrint('Helba push: notification permission=$status');
      if (status.isPermanentlyDenied) {
        pushNotificationsPermanentlyDenied.value = true;
      } else if (status.isGranted) {
        pushNotificationsPermanentlyDenied.value = false;
      }
    } catch (e) {
      // A denied notification permission just means no banners; the app
      // still works, and the user can enable it later from settings.
      debugPrint('Helba push: notification permission request failed: $e');
    }
  }
}

/// Stores [fid] (this install's Firebase Installation ID) for the
/// current user (insert or refresh updated_at on conflict). Retried
/// with backoff (finding #16): 3 attempts, ~1s / ~3s / ~8s apart, so a
/// network blip at sign-in no longer leaves the device unregistered
/// until the next restart. If all attempts fail, the FID is kept in
/// [_pendingFid] for [retryPushTokenUpsert] on the next sign-in.
/// Best-effort: a failed upsert never throws.
Future<void> _upsertPushToken(String fid) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null || !isValidPushToken(fid)) return;
  const delays = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];
  for (var attempt = 0; attempt < 3; attempt++) {
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
      _currentFid = fid.trim();
      _pendingFid = null;
      // The FID is confirmed stored: registration is verified (fix 9),
      // so any earlier warning is cleared.
      _pushTokenUpsertConfirmed = true;
      pushRegistrationWarning.value = null;
      return;
    } catch (e) {
      // The token table (migration 011) may not be applied yet, or the
      // network blipped; log (no PII — only the attempt number) and
      // retry, instead of silently giving up (finding #16/#19).
      debugPrint('Helba push: token upsert attempt ${attempt + 1}/3 failed: $e');
      if (attempt < 2) {
        await Future.delayed(delays[attempt]);
      }
    }
  }
  _pendingFid = fid.trim();
  _pushTokenUpsertConfirmed = false;
  debugPrint('Helba push: token upsert failed after 3 attempts; will retry '
      'on next sign-in');
  // Fix 9: do not fail silently — without a stored token this device
  // receives no closed-app push. The warning is cleared by the next
  // successful upsert (above) or the next setup's verification.
  pushRegistrationWarning.value =
      'تعذّر تسجيل الإشعارات على هذا الجهاز — لن تصلك المكالمات والرسائل والهاتف مغلق. تحقق من الاتصال ثم أعد فتح التطبيق.';
}

/// Shows a foreground FCM message as a local notification. The Edge
/// Function already sends title = sender name and body = preview, so the
/// notification fields are used as-is; the data payload is only trusted
/// for the conversation id (re-parsed through the chat deep-link rules).
///
/// Suppressed (finding #20) when the message is the user's own (same
/// account on a second device — the server-side sender exclusion only
/// covers the trigger path) or when that conversation is currently open
/// on screen ([currentOpenConversationId], set by ChatPage). The
/// notification id is the stable [stableNotificationId] (finding #17),
/// not `conversationId.hashCode`.
///
/// A call message (`data.type == 'call'`) takes a different path: it
/// queues [pendingIncomingCallPush] (CallService shows the incoming-call
/// overlay + ringtone) and, unless the overlay is already ringing for
/// it, shows a high-priority incoming-call notification on the
/// dedicated call channel (sound + vibration, full-screen intent) whose
/// tap opens the app to the incoming call screen.
Future<void> _showForegroundMessage(RemoteMessage message) async {
  try {
    final data = message.data;
    final call = parseCallPushData(data);
    if (call != null) {
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (currentUserId != null && call.callerId == currentUserId) {
        return;
      }
      // Queue the call first: CallService shows the overlay + ringtone,
      // and ignores it when already busy or ringing for this call.
      pendingIncomingCallPush.value = call;
      if (callRinging.value) return;
      final isVideo = call.callType == 'video';
      await _localNotifications.show(
        id: stableNotificationId(call.callId),
        title: call.callerName ?? 'هلبة',
        body: isVideo ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            pushCallsChannelId,
            'مكالمات هلبة',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: encodeCallPushPayload(call),
      );
      return;
    }
    final conversationId = data['conversation_id']?.toString().trim() ?? '';
    if (!isValidPushConversationId(conversationId)) return;
    final senderId = data['sender_id']?.toString().trim() ?? '';
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (senderId.isNotEmpty &&
        currentUserId != null &&
        senderId == currentUserId) {
      return;
    }
    if (currentOpenConversationId.value == conversationId) {
      return;
    }
    final title = buildNotificationTitle(message.notification?.title);
    final body = buildNotificationBody(
      message.notification?.body ?? data['body']?.toString(),
      data['message_type']?.toString(),
    );
    await _localNotifications.show(
      id: stableNotificationId(conversationId),
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
  } catch (e) {
    // A failed banner must never crash the app.
    debugPrint('Helba push: failed to show foreground message: $e');
  }
}

/// A notification tap (or a cold start from one) opens the chat. This
/// only sets pendingChatId; AuthGate owns the actual navigation (see
/// auth.dart), so the tap path and the `helba://chat/<id>` link share one
/// navigation handler. The id is only trusted when it is a well-formed
/// UUID (finding F7/F8).
///
/// A call message tap instead queues [pendingIncomingCallPush]:
/// CallService opens the incoming call screen once the user is signed
/// in (see startListening in calls.dart).
void _openChatFromMessage(RemoteMessage message) {
  final call = parseCallPushData(message.data);
  if (call != null) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId != null && call.callerId == currentUserId) return;
    pendingIncomingCallPush.value = call;
    return;
  }
  final conversationId =
      message.data['conversation_id']?.toString().trim() ?? '';
  if (isValidPushConversationId(conversationId)) {
    pendingChatId.value = conversationId;
  } else if (conversationId.isNotEmpty) {
    debugPrint(
      'Helba push: ignoring notification tap with invalid conversation id',
    );
  }
}
