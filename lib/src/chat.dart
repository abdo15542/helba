import 'dart:async';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:libsignal/libsignal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'admin.dart';
import 'calls.dart';
import 'channels.dart';
import 'config.dart';
import 'e2ee.dart';
import 'push.dart';
import 'signal_sync.dart';
import 'utils.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/chat_inbox_helpers_test.dart).
// ---------------------------------------------------------------------------

/// Timestamp for a chat message: HH:mm when the message is from today,
/// otherwise the date plus the time, so yesterday's messages are not
/// confused with today's.
String formatChatTime(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final sameDay = local.year == reference.year &&
      local.month == reference.month &&
      local.day == reference.day;
  if (sameDay) return DateFormat('HH:mm').format(local);
  return DateFormat('yyyy-MM-dd HH:mm').format(local);
}

/// True when an encrypted row is missing the ciphertext or the nonce it
/// needs to be decrypted at all. Such rows are malformed, not merely
/// undecryptable, and must never be permanently marked "decrypt failed".
///
/// Signal rows are the exception: they carry their nonce inside the
/// serialized Signal ciphertext, so their `nonce` column is NULL by
/// design. A Signal row is malformed only when its ciphertext is empty
/// or its `signal_msg_type` is missing/invalid.
bool isMalformedEncryptedRow(Map<String, dynamic> row) {
  if (!isEncryptedMessage(row)) return false;
  final ciphertext = row['ciphertext']?.toString() ?? '';
  if (isSignalMessageRow(row)) {
    return ciphertext.isEmpty;
  }
  final nonce = row['nonce']?.toString() ?? '';
  return ciphertext.isEmpty || nonce.isEmpty;
}

/// The plaintext-banner message for a conversation whose messages are
/// currently going out unencrypted. The banner is shown whenever there
/// is no conversation key OR a member lacks a public key — but the two
/// causes must not be confused: when every member HAS a valid key on at
/// least one device, the key itself failed to load (e.g. a wrapped row
/// that unwraps with neither KEK), and blaming a missing member key
/// sends the user chasing a member who already has one. Pure
/// (unit-tested).
String plaintextBannerMessage(
        Map<String, List<DeviceKey>> memberDeviceKeys) =>
    canEncryptFor(memberDeviceKeys)
        ? '🔓 غير مشفّرة — تعذّر تحميل مفتاح التشفير'
        : '🔓 غير مشفّرة — أحد الأعضاء بلا مفتاح';

/// Maximum Signal decrypt attempts for one row before it is marked
/// failed (tap-to-retry) instead of left pending. A Signal row that
/// fails once is usually a transient race (the session was still
/// converging when the message arrived), not a lost key — so it gets
/// a bounded retry budget, never the permanent label on first
/// failure. Pure (unit-tested via [signalDecryptShouldRetry]).
const maxSignalDecryptAttempts = 3;

/// True when [row] is a Signal row sent by the current user.
///
/// A Signal sender cannot decrypt their own outgoing ciphertext
/// (the sending ratchet has moved on; the session holds the receiving
/// chain for the peer, not the sender's own outgoing message keys),
/// so such rows must never enter the decrypt pipeline — they are
/// shown from the plaintext stored on this device at send time
/// ([SentSignalPlaintextStore]). Old-E2E rows are NOT affected: their
/// conversation key is shared, so the sender can decrypt those.
/// Pure (unit-tested).
bool isOwnSignalRow(Map<String, dynamic> row, String? currentUserId) {
  if (currentUserId == null || currentUserId.isEmpty) return false;
  if (!isSignalMessageRow(row)) return false;
  return row['sender_id']?.toString() == currentUserId;
}

/// True when a Signal row that failed to decrypt should be retried
/// (left pending for the next decrypt pass) instead of marked failed.
/// Pure (unit-tested).
bool signalDecryptShouldRetry(int attempts) =>
    attempts < maxSignalDecryptAttempts;

/// True when a Signal row that exhausted its decrypt budget should
/// trigger one automatic session heal: the budget is spent AND the
/// row has not already healed once. A row whose ciphertext is gone
/// for good must not rebuild the session on every open — one heal
/// per message, then the row stays failed with a manual retry.
/// Pure (unit-tested via [shouldHealSessionAfterFailure]).
bool shouldHealSessionAfterFailure({
  required int attempts,
  required bool wasHealed,
}) =>
    attempts >= maxSignalDecryptAttempts && !wasHealed;

/// True when returning to the app should re-fetch the message list.
///
/// The list is fed only by the Realtime stream, built once in
/// `initState`. If that stream silently disconnects (network blip,
/// app backgrounded, socket drop) without emitting a terminal error,
/// the list freezes — rows that arrived while away (including the
/// user's own sends, which only come back via the stream) never
/// appear until the chat is fully closed and reopened. Rebuilding
/// the stream on `resumed` re-runs its initial query, so the list
/// catches up when the user comes back (including the
/// tap-a-push-notification flow). Only `resumed` refreshes —
/// `inactive`, `paused`, `hidden` and `detached` must not, or every
/// backgrounding would churn the subscription. Pure (unit-tested).
bool shouldRefreshMessagesOnResume(AppLifecycleState state) =>
    state == AppLifecycleState.resumed;

/// How often the fallback list re-fetches while the Realtime stream
/// is down (build 134): the stream has errored, so without polling
/// new rows would never appear until the user manually retries /
/// pulls / reopens the chat. Five seconds keeps the list fresh
/// without hammering the server.
const fallbackPollInterval = Duration(seconds: 5);

/// True when the fallback poll should be running: the fallback list
/// is active (the Realtime stream errored and saved rows are being
/// shown) AND the app is in the foreground. Polling must not run in
/// the background. Pure (unit-tested).
bool shouldPollFallbackMessages({
  required bool fallbackActive,
  required bool isForeground,
}) =>
    fallbackActive && isForeground;

/// True when one fallback poll tick should run a fetch: the fallback
/// list is active, the conversation id is valid, and no fetch is
/// already in flight (a second tick while one is loading is skipped
/// — no overlapping fetches). Pure (unit-tested).
bool shouldRunFallbackPollTick({
  required bool fallbackActive,
  required bool validConversationId,
  required bool fallbackLoading,
}) =>
    fallbackActive && validConversationId && !fallbackLoading;

/// True when a freshly fetched fallback list differs from the one
/// currently shown, by row count or by row-id sequence (oldest
/// first). An unchanged fetch must not setState: it would rebuild
/// the list every poll tick and re-run decryption needlessly. A new,
/// removed, or replaced row changes the ids/count and must update.
/// Pure (unit-tested).
bool fallbackRowsChanged(
  List<Map<String, dynamic>> oldRows,
  List<Map<String, dynamic>> newRows,
) {
  if (oldRows.length != newRows.length) return true;
  for (var i = 0; i < oldRows.length; i++) {
    if (oldRows[i]['id']?.toString() != newRows[i]['id']?.toString()) {
      return true;
    }
  }
  return false;
}

/// What an encrypted message row should show. Pure (unit-tested via
/// [encryptedRowBody]) — the widget only renders the decision.
enum EncryptedRowBody {
  /// Decrypted (peer message, or an old-E2E own message): show the
  /// plaintext with the encrypted label.
  decrypted,

  /// Own Signal message with a locally stored plaintext: show it
  /// with the encrypted label (never re-decrypted).
  ownPlaintext,

  /// Own Signal message with no stored plaintext (sent from another
  /// device / local storage cleared): show the encrypted placeholder
  /// with the encrypted label — never a decryption failure.
  ownPlaceholder,

  /// Malformed row (missing ciphertext/type): "رسالة تالفة".
  malformed,

  /// Ciphertext encrypted under a key that is gone for good (old-E2E
  /// only; Signal rows never reach this state): permanent label, no
  /// retry.
  permanentlyUnreadable,

  /// Failed after the bounded Signal retry budget (or a definitive
  /// old-E2E key failure): failure label with tap-to-retry.
  failed,

  /// Still pending: placeholder with the "decrypting…" spinner.
  decrypting,
}

/// Decides what an encrypted row shows, from the decrypt state.
///
/// The own-Signal case is checked FIRST, before every failure set:
/// an own Signal row is never decrypted and must never show a
/// failure label, even if it somehow landed in a failure set. Pure
/// (unit-tested).
EncryptedRowBody encryptedRowBody({
  required Map<String, dynamic> row,
  required String? currentUserId,
  required Map<String, String> decrypted,
  required Map<String, String> ownSentPlaintext,
  required Set<String> malformedIds,
  required Set<String> permanentlyUnreadable,
  required Set<String> decryptFailed,
}) {
  final id = row['id']?.toString() ?? '';
  if (isOwnSignalRow(row, currentUserId)) {
    return ownSentPlaintext.containsKey(id)
        ? EncryptedRowBody.ownPlaintext
        : EncryptedRowBody.ownPlaceholder;
  }
  if (decrypted.containsKey(id)) return EncryptedRowBody.decrypted;
  if (malformedIds.contains(id)) return EncryptedRowBody.malformed;
  if (permanentlyUnreadable.contains(id)) {
    return EncryptedRowBody.permanentlyUnreadable;
  }
  if (decryptFailed.contains(id)) return EncryptedRowBody.failed;
  return EncryptedRowBody.decrypting;
}

/// Empty key loads after which pending encrypted rows stop spinning on
/// "جارٍ فك التشفير…" and are marked failed (retryable) instead
/// (fix 5). A load counts as empty when it returns no key without a
/// definitive block — the creator has not created a key yet, or the
/// key is still missing for another transient reason.
const keyLoadGiveUpAttempts = 3;

class ChatPage extends StatefulWidget {
  final String conversationId, title;
  final String kind;
  final bool isAdmin;
  const ChatPage(
      {super.key,
      required this.conversationId,
      required this.title,
      this.kind = 'direct',
      this.isAdmin = false});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final input = TextEditingController();
  final _scroll = ScrollController();
  bool sending = false;
  int _lastMessageCount = -1;
  final client = Supabase.instance.client;

  // The message stream must live in state: building it inside build() made
  // every rebuild (each send, each parent rebuild) resubscribe and flash
  // the list with a loading spinner. It is nullable so an invalid
  // conversation id can show a "not found" state instead of a stream
  // that immediately fails with a PostgREST 400.
  Stream<List<Map<String, dynamic>>>? _messagesStream;
  bool _validConversationId = false;

  // One-off plain-select fallback for a Realtime-only stream failure:
  // the rows are shown with a "live updates disconnected" hint instead
  // of a full error screen.
  List<Map<String, dynamic>>? _fallbackRows;
  bool _fallbackLoading = false;

  // Periodic plain-select poll while the Realtime fallback list is
  // active (build 134): the stream has errored, so without polling
  // new rows would never appear until the user manually retries /
  // pulls / reopens the chat. Started when the fallback becomes
  // active, stopped when the stream is rebuilt (retry / resume /
  // pull), when the app leaves the foreground, and in dispose().
  // Never runs in the background.
  Timer? _fallbackPollTimer;
  // True while the app is in the foreground (updated by
  // [didChangeAppLifecycleState]). Polling only runs in the
  // foreground (see [shouldPollFallbackMessages]).
  bool _appInForeground = true;

  Map<String, String> _memberNames = {};
  final Set<String> _memberIds = {};
  bool _isGroup = false;
  bool _membersLoaded = false;
  bool _membersLoading = true;
  bool _membersError = false;

  // E2E encryption state (see lib/src/e2ee.dart for the honest limits).
  // Members' device keys, keyed by user id: one entry per registered
  // device plus the legacy per-user entry (deviceId null, from
  // profiles.public_key). An empty list means "no key yet" for that
  // member (see [loadMemberDeviceKeys]).
  Map<String, List<DeviceKey>> _memberDeviceKeys = {};
  // Decrypted bodies of encrypted messages, keyed by message id.
  final Map<String, String> _decrypted = {};
  final Set<String> _decrypting = {};
  final Set<String> _decryptFailed = {};
  // Encrypted rows that cannot be decrypted because ciphertext/nonce
  // is missing (malformed), shown as "رسالة تالفة" — never in
  // _decryptFailed, so a later key load does not mislabel them.
  final Set<String> _malformedIds = {};
  // Encrypted rows that failed to decrypt WITH a loaded key (fix 5):
  // their ciphertext was encrypted under a key this device no longer
  // has (lost on reinstall / deleted by a reset). No retry can ever
  // succeed, so they are labelled permanently unreadable in the UI
  // with NO retry link, instead of spinning on "جارٍ فك التشفير…" or
  // offering a futile "إعادة المحاولة". Unlike _decryptFailed (key
  // missing/blocked — a reset may heal it), these never leave this set
  // except on a reset, which re-evaluates them against the fresh key.
  final Set<String> _permanentlyUnreadable = {};
  // Plaintexts of Signal messages THIS device sent, keyed by message
  // id (see [SentSignalPlaintextStore]): a Signal sender cannot
  // decrypt their own outgoing ciphertext, so own sent Signal rows
  // are shown from this map (loaded from on-device storage when rows
  // arrive, populated immediately at send time). Deliberately NOT
  // cleared on reset — the plaintexts do not depend on any key or
  // session.
  final Map<String, String> _ownSentPlaintext = {};
  // Signal decrypt attempts are NOT kept in memory here: they live
  // in the persistent [SignalDecryptAttemptStore] on [SignalSync]
  // (secure storage), so the bounded retry budget
  // ([signalDecryptShouldRetry]) survives closing and reopening the
  // chat. A row that keeps failing reaches [_decryptFailed] instead
  // of spinning on "جارٍ فك التشفير…" forever.
  List<int>? _conversationKey;
  // True ONLY once a non-null key has actually been loaded. A null key
  // must not set this, otherwise the key load never retries.
  bool _conversationKeyLoaded = false;
  // The key load currently in flight, if any (fix 3): a second request
  // awaits it instead of silently dropping its own load — the reset's
  // load used to be dropped this way when _initChat's load was still
  // running. [_keyLoadInFlightAfterReset] records whether the in-flight
  // load is a reset load, so a reset load still runs after a plain one
  // (only it may create a key when encrypted messages exist).
  Future<void>? _keyLoadInFlight;
  bool _keyLoadInFlightAfterReset = false;
  // Generation counter for key loads (fix 3): incremented by
  // _resetEncryption, so a load that started BEFORE the reset cannot
  // apply a stale key after the reset deleted the rows. A load that
  // finds its generation outdated discards its result.
  int _keyLoadGeneration = 0;
  // Consecutive key loads that returned no key without a definitive
  // block (fix 5): after [_keyLoadGiveUpAttempts] of them, pending
  // encrypted rows stop spinning on "جارٍ فك التشفير…" and are marked
  // failed (retryable) instead. Reset when a key loads, or when the
  // user taps retry.
  int _keyLoadNullCount = 0;
  // Members the last key-creation wrap wrote NO row for (fix 1):
  // _resetEncryption warns when this is non-empty.
  Set<String> _lastWrapUncovered = {};
  // Signal Protocol (1:1 chats only): the sync layer for this device.
  // Null when there is no signed-in user or the native library cannot
  // initialise — 1:1 sends then fall back to plaintext. [_signalSync]
  // is created in [_initChat] (after members load) and publishes this
  // device's pre-key bundle in the background.
  SignalSync? _signalSync;
  // True once a Signal session exists for the other member of a 1:1
  // chat (so new messages go out Signal-encrypted). Drives the
  // plaintext banner for 1:1 chats, which must not blame the old
  // conversation key that 1:1 no longer uses.
  bool _signalSessionReady = false;
  // One-time-per-session publish-failure warning (fix 4).
  bool _publishWarningShown = false;
  // Periodic key-load retry while the chat is open and keyless (fix 6):
  // a fresh reset (e.g. from the other phone) takes effect without
  // reopening the chat, instead of waiting for new stream data.
  Timer? _keyRetryTimer;
  // True when the last key load DEFINITIVELY failed: my wrapped row
  // exists but cannot be unwrapped with either KEK (corrupt row, or
  // wrapped for a key this device no longer holds). Unlike a transient
  // failure (no row yet / network), this will not heal by waiting, so
  // the decrypt UI shows a failure + retry instead of an eternal
  // "decrypting…" spinner. Cleared when a key loads, or when the user
  // taps retry (the load then re-decides it).
  bool _keyDefinitivelyBlocked = false;
  bool _decryptRunning = false;
  // Bounded key-load retry: at most one retry per ~10s, triggered by new
  // stream data — never a hot loop.
  DateTime? _lastKeyRetryAt;
  // Last rows seen, so a key that loads late can re-run decryption.
  List<Map<String, dynamic>> _lastRows = [];
  Set<String> _lastEncryptedIds = {};

  // Double-tap guard for _startCall (the service-level guard is in
  // calls.dart, not here).
  bool _startingCall = false;

  // Mute state, cached per ChatPage session (F42). Loaded once in
  // initState; a missing muted_until column (backend migration not yet
  // applied) is treated as "not muted", never a crash.
  DateTime? _mutedUntil;
  bool _mutedLoaded = false;

  // One-time-per-session plaintext-downgrade warning (B-12).
  bool _plaintextDowngradeWarned = false;

  Stream<List<Map<String, dynamic>>> _buildMessagesStream() =>
      client.from('messages').stream(primaryKey: ['id']).eq(
          'conversation_id', widget.conversationId).order('created_at',
          ascending: true).limit(200);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Suppress foreground push banners for this conversation while it is
    // open (push.dart reads this; cleared in dispose()).
    currentOpenConversationId.value = widget.conversationId;
    _validConversationId = isValidUuid(widget.conversationId);
    if (_validConversationId) {
      _messagesStream = _buildMessagesStream();
    }
    // Members first, THEN the key: the key must be wrapped for the
    // members we actually know about, not just for the creator.
    _initChat();
    _loadMutedUntil();
    // Fix 6: while the chat is open and keyless, retry the key load
    // every ~10s (bounded by _maybeRetryKeyLoad) so a fresh reset —
    // e.g. from the other phone — takes effect without reopening the
    // chat. _maybeRetryKeyLoad is a no-op once a key is loaded.
    _keyRetryTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        if (mounted) _maybeRetryKeyLoad();
      },
    );
  }

  Future<void> _initChat() async {
    await _loadMembers();
    if (!mounted) return;
    // Signal (1:1): wire the sync layer and publish this device's
    // pre-key bundle in the background (best-effort, never blocks the
    // chat). For a 1:1 chat, also warm the session to the other member
    // so the first send is already encrypted.
    await _initSignal();
    if (!mounted) return;
    if (_isDirectChat) await _warmSignalSession();
    if (!mounted) return;
    await _ensureConversationKey();
  }

  /// Wires [_signalSync] for the signed-in user and publishes this
  /// device's pre-key bundle in the background. Best-effort: a null
  /// result (no user, native library unavailable) just means 1:1
  /// sends fall back to plaintext.
  Future<void> _initSignal() async {
    if (_signalSync != null) return;
    try {
      final sync = await SignalSync.forCurrentUser();
      if (!mounted) return;
      _signalSync = sync;
      if (sync != null) {
        // Fire-and-forget: publishing must not delay opening the chat;
        // it retries on the next chat open when offline.
        unawaited(sync.ensurePublished());
      }
    } catch (_) {
      // Signal unavailable; 1:1 sends fall back to plaintext.
    }
  }

  /// Warms the Signal session to the other member of a 1:1 chat (the
  /// recipient need not be online — the session is built from their
  /// published bundle). Sets [_signalSessionReady] so the plaintext
  /// banner and the send path know Signal is available. Best-effort.
  Future<void> _warmSignalSession() async {
    final sync = _signalSync;
    final otherId = _otherUserId;
    if (sync == null || otherId == null) return;
    final deviceUuids = _memberDeviceUuids(otherId);
    for (final deviceUuid in deviceUuids) {
      try {
        if (await sync.ensureSessionFor(otherId, deviceUuid)) {
          if (mounted) setState(() => _signalSessionReady = true);
          // The session just healed: retry any Signal rows that
          // failed while it was being established (bounded retry in
          // _decryptSignalRows).
          unawaited(_decryptPendingRows(_lastRows));
          return;
        }
      } catch (_) {
        // Try the next device.
      }
    }
  }

  /// The other member's device uuids (from the member device map),
  /// sorted for determinism. Empty when members are not loaded yet.
  List<String> _memberDeviceUuids(String userId) {
    final devices = _memberDeviceKeys[userId] ?? const [];
    final uuids = devices
        .map((d) => d.deviceId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList()
      ..sort();
    return uuids;
  }

  /// Recreates the message stream after a terminal stream error, and
  /// clears any plain-select fallback so live updates take over again.
  void _retryMessages() {
    if (!_validConversationId) return;
    // The stream is rebuilt, so the fallback (and its poll) go away:
    // live updates take over again.
    _stopFallbackPoll();
    setState(() {
      _messagesStream = _buildMessagesStream();
      _fallbackRows = null;
      _fallbackLoading = false;
    });
  }

  /// Re-fetch the message list when the app comes back to the
  /// foreground. The list is fed only by the Realtime stream built
  /// once in [initState]; a stream that silently disconnects (no
  /// terminal error) freezes the list, so rows that arrived while
  /// away — including the user's own sends — never appear until the
  /// chat is reopened. Rebuilding the stream re-runs its initial
  /// query, so the list catches up on resume (including the
  /// tap-a-push-notification flow). Only `resumed` refreshes (see
  /// [shouldRefreshMessagesOnResume]).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (!shouldRefreshMessagesOnResume(state)) {
      // App left the foreground: pause fallback polling — it must
      // not run in the background. On return, the stream rebuild
      // below takes over again; if it errors again the fallback (and
      // its poll) restarts from _loadFallbackMessages.
      _stopFallbackPoll();
      return;
    }
    if (!mounted) return;
    _retryMessages();
  }

  /// Pull-to-refresh for the message list: rebuilds the Realtime
  /// stream (same as [_retryMessages]) so a silently disconnected
  /// stream is re-fetched on demand. The short delay keeps the
  /// indicator visible long enough to be seen; the stream's initial
  /// query runs immediately on rebuild.
  Future<void> _refreshMessages() async {
    _retryMessages();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  /// The plain-select query behind the fallback list (shared by
  /// [_loadFallbackMessages] and the fallback poll): all messages of
  /// this conversation, oldest first, capped at 200.
  Future<List<Map<String, dynamic>>> _fetchFallbackRows() async {
    final rows = await client
        .from('messages')
        .select()
        .eq('conversation_id', widget.conversationId)
        .order('created_at', ascending: true)
        .limit(200)
        .timeout(const Duration(seconds: 15));
    return rows.cast<Map<String, dynamic>>();
  }

  /// Plain-select fallback: used only when the Realtime stream has
  /// errored. Shows the messages with a "live updates disconnected"
  /// hint instead of a full error screen.
  Future<void> _loadFallbackMessages() async {
    if (_fallbackLoading || !_validConversationId) return;
    _fallbackLoading = true;
    try {
      final rows = await _fetchFallbackRows();
      if (!mounted) return;
      setState(() {
        _fallbackRows = rows;
      });
      // The stream has errored and saved rows are being shown: start
      // polling so new messages appear without the user having to
      // retry / pull / reopen (build 134).
      _startFallbackPoll();
    } catch (_) {
      // Stay on the error screen; the retry button is still there.
    } finally {
      _fallbackLoading = false;
    }
  }

  /// Starts the fallback poll if it is not already running and
  /// polling is wanted right now (fallback active + app
  /// foregrounded — see [shouldPollFallbackMessages]). A no-op
  /// otherwise, so repeated calls cannot stack timers.
  void _startFallbackPoll() {
    if (_fallbackPollTimer != null) return;
    if (!shouldPollFallbackMessages(
      fallbackActive: _fallbackRows != null,
      isForeground: _appInForeground,
    )) {
      return;
    }
    _fallbackPollTimer = Timer.periodic(
      fallbackPollInterval,
      (_) {
        if (mounted) _pollFallbackMessages();
      },
    );
  }

  /// Stops the fallback poll, if running. Called when the stream is
  /// rebuilt (retry / resume / pull), when the app leaves the
  /// foreground, and in dispose().
  void _stopFallbackPoll() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = null;
  }

  /// One fallback poll tick: re-runs the plain-select fetch and
  /// updates the list only when the rows actually changed (see
  /// [fallbackRowsChanged]), so an unchanged fetch costs no rebuild
  /// and no decryption re-run. Skips the tick when a fetch is
  /// already in flight (no overlapping fetches), when the fallback
  /// is no longer active, or when the widget is gone. A failed fetch
  /// is silently skipped — the next tick retries, and the
  /// stale-but-visible list beats an error screen. Never throws.
  /// Newly arrived encrypted rows are decrypted by the existing
  /// [_buildMessageList] path (it calls [_decryptPendingRows] when
  /// the rows change).
  Future<void> _pollFallbackMessages() async {
    if (!shouldRunFallbackPollTick(
      fallbackActive: _fallbackRows != null,
      validConversationId: _validConversationId,
      fallbackLoading: _fallbackLoading,
    )) {
      return;
    }
    _fallbackLoading = true;
    try {
      final rows = await _fetchFallbackRows();
      if (!mounted || _fallbackRows == null) return;
      if (!fallbackRowsChanged(_fallbackRows!, rows)) return;
      setState(() {
        _fallbackRows = rows;
      });
    } catch (_) {
      // Next tick retries.
    } finally {
      _fallbackLoading = false;
    }
  }

  /// Member display names, so group messages show who wrote them.
  /// Also loads members' E2E public keys. The public_key select fails
  /// when migration 012 has not been applied yet (unknown column), so
  /// fall back to the old select — names must keep working either way.
  /// On failure the error is surfaced (snackbar + retry affordance in
  /// the AppBar/body) instead of swallowed: with no members, call
  /// buttons and the report menu would silently disappear and sends
  /// would go plaintext with no warning.
  Future<void> _loadMembers({bool silent = false}) async {
    if (mounted) setState(() => _membersLoading = true);
    try {
      List rows;
      try {
        rows = await client.from('conversation_members')
          .select('user_id,profiles(display_name,username,public_key)')
          .eq('conversation_id', widget.conversationId)
          .timeout(const Duration(seconds: 15));
      } catch (_) {
        rows = await client.from('conversation_members')
          .select('user_id,profiles(display_name,username)')
          .eq('conversation_id', widget.conversationId)
          .timeout(const Duration(seconds: 15));
      }
      final names = <String, String>{};
      final ids = <String>{};
      final keys = <String, String?>{};
      for (final row in rows) {
        if (row is! Map) continue;
        ids.add(row['user_id'].toString());
        final profile = row['profiles'] as Map<String, dynamic>?;
        final publicKey = profile?['public_key']?.toString();
        keys[row['user_id'].toString()] =
            (publicKey?.trim().isNotEmpty == true) ? publicKey : null;
        final name = profile?['display_name']?.toString().trim().isNotEmpty == true
            ? profile!['display_name'].toString()
            : (profile?['username']?.toString().isNotEmpty == true
                ? '@${profile!['username']}'
                : '');
        if (name.isNotEmpty) names[row['user_id'].toString()] = name;
      }
      if (mounted) {
        // Per-device keys (migration 023): each member's registered
        // devices plus the legacy per-user entry from profiles. The
        // legacy map above is the fallback when a member has no
        // device rows (or the user_devices read fails).
        final deviceKeys = await loadMemberDeviceKeys(keys);
        if (!mounted) return;
        setState(() {
          _memberNames = names;
          _memberIds
            ..clear()
            ..addAll(ids);
          _memberDeviceKeys = deviceKeys;
          // Group = more than two member ids, not more than two
          // non-empty display names (M-1).
          _isGroup = ids.length > 2;
          _membersLoaded = true;
          _membersLoading = false;
          _membersError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _membersLoading = false;
          _membersError = true;
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'تعذر تحميل بيانات الأعضاء. ${networkErrorMessage(e) ?? 'تحقق من الاتصال وحاول مجدداً.'}')),
          );
        }
      }
    }
  }

  void _retryMembers() {
    setState(() => _membersError = false);
    _loadMembers();
  }

  /// Loads (or creates, when the conversation has none yet) this
  /// conversation's E2E key. Best-effort: a null key only means this chat
  /// sends/reads plaintext, it never blocks the chat itself.
  /// _conversationKeyLoaded is set ONLY when a non-null key is in hand,
  /// so a transient failure retries instead of being remembered forever.
  /// When the key does arrive late, previously failed decryptions are
  /// cleared and re-attempted against the rows last seen.
  ///
  /// Fix 3: a load already in flight is AWAITED instead of silently
  /// dropping this request — the reset's load used to be dropped when
  /// _initChat's load was still running, leaving the conversation
  /// keyless after the reset. A reset load (afterReset: true) still
  /// runs after a plain load finishes, because only it may create a
  /// key when encrypted messages exist; an identical load does not
  /// re-run (the bounded retry covers it) — unless a reset invalidated
  /// the in-flight load while it was running, in which case this
  /// request runs regardless.
  Future<void> _ensureConversationKey({bool afterReset = false}) async {
    if (_conversationKey != null) {
      if (!_conversationKeyLoaded && mounted) {
        setState(() => _conversationKeyLoaded = true);
      }
      return;
    }
    final inFlight = _keyLoadInFlight;
    if (inFlight != null) {
      final inFlightWasReset = _keyLoadInFlightAfterReset;
      final generationBefore = _keyLoadGeneration;
      await inFlight;
      if (_conversationKey != null) {
        if (!_conversationKeyLoaded && mounted) {
          setState(() => _conversationKeyLoaded = true);
        }
        return;
      }
      if (inFlightWasReset == afterReset &&
          generationBefore == _keyLoadGeneration) {
        return;
      }
    }
    final generation = _keyLoadGeneration;
    final load = _loadConversationKey(
      afterReset: afterReset,
      generation: generation,
    );
    _keyLoadInFlight = load;
    _keyLoadInFlightAfterReset = afterReset;
    try {
      await load;
    } finally {
      if (identical(_keyLoadInFlight, load)) _keyLoadInFlight = null;
    }
  }

  /// The actual key-load work for [_ensureConversationKey]. [generation]
  /// is the [_keyLoadGeneration] captured when the load started: if a
  /// reset incremented it meanwhile, this load's result is discarded
  /// (the reset's own load runs after it) instead of applying a stale
  /// key for rows the reset just deleted.
  Future<void> _loadConversationKey({
    required bool afterReset,
    required int generation,
  }) async {
    try {
      final pair = await ensureKeyPair();
      // Fix 4: a failed/unverified publish warns the user (once per
      // session) instead of being swallowed — without a published key,
      // other members cannot wrap the conversation key for this device.
      // Publishing must never block the chat (e.g. pre-migration 012).
      final published = await publishPublicKeyIfNeeded(pair: pair);
      if (!published) _warnPublishFailed();
      final loaded = await loadOrCreateConversationKey(
        widget.conversationId,
        _memberDeviceKeys,
        afterReset: afterReset,
      );
      // A reset happened while this load was running: discard the
      // result — the reset's own load will create the fresh key.
      if (generation != _keyLoadGeneration) return;
      final key = loaded.key;
      if (mounted) {
        setState(() {
          // Whether the last load definitively failed (a wrapped row
          // exists but unwraps with neither KEK). Transient outcomes
          // (no row yet / network) report blocked: false, so pending
          // rows stay in "decrypting" and keep their bounded retry.
          _keyDefinitivelyBlocked = loaded.blocked;
          _lastWrapUncovered = loaded.uncoveredMembers;
          if (key != null) {
            _conversationKey = key;
            _conversationKeyLoaded = true;
            _keyLoadNullCount = 0;
            // The key is here now: rows marked failed only because
            // there was no key get another chance.
            _decryptFailed.clear();
          } else if (!loaded.blocked) {
            // Empty load (no key, no definitive block): count it
            // towards the give-up threshold (fix 5).
            _keyLoadNullCount++;
          }
        });
      }
      if (key != null) {
        if (loaded.fromLegacy) {
          // Heal: the key came from a pre-binding (legacy) wrapped
          // row — re-wrap it for all members with the bound KEK, so
          // the row is readable by the current code path and future
          // loads no longer depend on the fallback. Best-effort: the
          // key itself already loaded, a heal failure must not break
          // the chat. The re-wrap is per device (migration 023);
          // [wrapKeyForMembers] refreshes my own device entry with
          // the current local public key (finding #21).
          try {
            final healUncovered = await wrapKeyForMembers(
                widget.conversationId, key, _memberDeviceKeys);
            if (mounted) {
              setState(() => _lastWrapUncovered = healUncovered);
            }
          } catch (_) {
            // Heal is best-effort; the key itself already loaded.
          }
        }
        if (mounted && _lastRows.isNotEmpty) {
          _decryptPendingRows(_lastRows);
        }
      } else if (loaded.blocked && mounted && _lastRows.isNotEmpty) {
        // Definitive key failure: re-run decryption so the pending
        // encrypted rows are marked failed (they show a retry
        // affordance) instead of spinning on "decrypting…" forever.
        _decryptPendingRows(_lastRows);
      } else if (mounted &&
          _lastRows.isNotEmpty &&
          _keyLoadNullCount >= keyLoadGiveUpAttempts) {
        // Fix 5: no key after several empty loads and no definitive
        // block — stop spinning on the pending rows. _decryptPendingRows
        // marks them failed (retryable) at the give-up threshold.
        _decryptPendingRows(_lastRows);
      }
    } catch (_) {
      // Deliberately do NOT set _conversationKeyLoaded: a transient
      // failure must be retryable (bounded, see _maybeRetryKeyLoad).
    }
  }

  /// One-time-per-session warning when my public key could not be
  /// published/verified (fix 4): without it, other members cannot wrap
  /// the conversation key for this device and my messages go out
  /// plaintext. Best-effort: never throws, never blocks the chat.
  void _warnPublishFailed() {
    if (_publishWarningShown || !mounted) return;
    _publishWarningShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'تعذّر نشر مفتاح التشفير الخاص بك — قد تصل رسائلك غير مشفّرة. تحقق من الاتصال وأعد فتح المحادثة.'),
      ),
    );
  }

  /// Bounded key retry: at most once per ~10s, only when new stream
  /// data arrives while there is still no key. Also driven by the
  /// open-chat timer (fix 6), so a fresh reset takes effect without
  /// reopening the chat.
  void _maybeRetryKeyLoad() {
    if (_conversationKey != null || _keyLoadInFlight != null) return;
    final now = DateTime.now();
    if (_lastKeyRetryAt != null &&
        now.difference(_lastKeyRetryAt!).inSeconds < 10) {
      return;
    }
    _lastKeyRetryAt = now;
    _ensureConversationKey();
  }

  /// Decrypts encrypted rows that arrived in the stream and are not yet
  /// cached, failed, or in flight. Runs after the frame (never setState
  /// in a loop, never re-decrypt a cached row) and only one run at a time.
  ///
  /// Signal rows (1:1 chats) are decrypted first and need NO old
  /// conversation key — they use the Signal session for the sender's
  /// device. Old-E2E rows keep the existing key-load gate below.
  /// Malformed rows (missing ciphertext/nonce) are skipped, never marked
  /// failed. Rows that cannot be decrypted only because the key is null
  /// are NOT marked failed either — they are retried when the key loads
  /// — EXCEPT when the key load definitively failed (a wrapped row
  /// exists but unwraps with neither KEK) or after several empty loads
  /// (fix 5): those rows are marked failed so the UI shows "تعذّر فك
  /// التشفير" with a tap-to-retry instead of an eternal "جارٍ فك
  /// التشفير…". A row whose decryption THROWS with a loaded key is
  /// different: its ciphertext was encrypted under a key that is gone
  /// for good, so it goes to [_permanentlyUnreadable] (no retry — the
  /// retry can never succeed) instead of [_decryptFailed].
  Future<void> _decryptPendingRows(List<Map<String, dynamic>> rows) async {
    // Own sent Signal rows are displayed from the locally stored
    // plaintext (never decrypted); load it in the background even
    // when a decrypt run is already in flight.
    unawaited(_loadOwnSentPlaintexts(rows));
    if (_decryptRunning) return;
    final malformed = <String>[];
    final signalPending = <Map<String, dynamic>>[];
    final oldPending = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (!isEncryptedMessage(row)) continue;
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      // Own Signal rows never enter the decrypt pipeline (the sender
      // cannot decrypt their own outgoing ciphertext) and never land
      // in _permanentlyUnreadable/_decryptFailed — see _messageBody.
      if (isOwnSignalRow(row, client.auth.currentUser?.id)) continue;
      if (isMalformedEncryptedRow(row)) {
        malformed.add(id);
        continue;
      }
      if (_decrypted.containsKey(id) ||
          _decrypting.contains(id) ||
          _decryptFailed.contains(id) ||
          _permanentlyUnreadable.contains(id)) {
        continue;
      }
      if (isSignalMessageRow(row)) {
        signalPending.add(row);
      } else {
        oldPending.add(row);
      }
    }
    if (malformed.isNotEmpty && mounted) {
      setState(() => _malformedIds.addAll(malformed));
    }
    // Signal rows first: they need no old conversation key.
    if (signalPending.isNotEmpty) {
      await _decryptSignalRows(signalPending);
      if (!mounted) return;
    }
    if (oldPending.isEmpty) return;
    final pending = oldPending;
    if (!_conversationKeyLoaded) {
      // No key yet. If the load already failed definitively, fall
      // through and mark the pending rows failed below — waiting
      // would never heal them. After several empty loads (fix 5),
      // also fall through: the rows cannot be decrypted with any key
      // available now. Otherwise trigger a (bounded) load and wait
      // for it.
      if (!_keyDefinitivelyBlocked &&
          _keyLoadNullCount < keyLoadGiveUpAttempts) {
        await _ensureConversationKey();
        if (!mounted) return;
        // Key load triggers a rebuild, which re-schedules this step.
        return;
      }
    }
    final key = _conversationKey;
    if (key == null) {
      // No key yet. A definitive load failure — or the give-up
      // threshold (fix 5) — marks these rows failed (retry affordance
      // in the UI). A transient failure (no row yet / network) leaves
      // them pending: the builder re-schedules decryption (bounded)
      // when new data arrives or the key loads.
      if ((_keyDefinitivelyBlocked ||
              _keyLoadNullCount >= keyLoadGiveUpAttempts) &&
          mounted) {
        setState(() {
          _decryptFailed
              .addAll(pending.map((row) => row['id'].toString()));
        });
      }
      return;
    }
    _decryptRunning = true;
    var changed = false;
    for (final row in pending) {
      final id = row['id'].toString();
      _decrypting.add(id);
      try {
        final plain = await decryptText(
          row['ciphertext']?.toString() ?? '',
          row['nonce']?.toString() ?? '',
          key,
        );
        _decrypted[id] = plain;
        changed = true;
      } catch (_) {
        // The key IS loaded and the ciphertext still does not decrypt:
        // it was encrypted under a key that is gone for good (lost on
        // reinstall / deleted by a reset). Permanently unreadable —
        // no retry link, and never back to the "decrypting…" spinner.
        _permanentlyUnreadable.add(id);
        changed = true;
      } finally {
        _decrypting.remove(id);
      }
    }
    _decryptRunning = false;
    if (changed && mounted) setState(() {});
  }

  /// Loads the locally stored plaintexts of this device's own sent
  /// Signal rows into [_ownSentPlaintext] (on-device storage only).
  /// Best-effort, never throws: a missing plaintext just shows the
  /// encrypted placeholder for that row.
  Future<void> _loadOwnSentPlaintexts(
    List<Map<String, dynamic>> rows,
  ) async {
    final sync = _signalSync;
    final myId = client.auth.currentUser?.id;
    if (sync == null || myId == null) return;
    var changed = false;
    for (final row in rows) {
      if (!isOwnSignalRow(row, myId)) continue;
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty || _ownSentPlaintext.containsKey(id)) continue;
      try {
        final plain = await sync.sentPlaintexts.read(id);
        if (plain != null && plain.isNotEmpty) {
          _ownSentPlaintext[id] = plain;
          changed = true;
        }
      } catch (_) {
        // Best-effort: the placeholder covers a missing plaintext.
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// Decrypts Signal Protocol rows (1:1 chats) with the Signal session
  /// for the sender's device. No old conversation key is needed. The
  /// sender's device is not stored on the row, so every device uuid
  /// known for the sender is tried in order — the one the sender
  /// actually used is the one whose session decrypts.
  ///
  /// A row that fails to decrypt is NOT permanently unreadable on a
  /// single attempt: the first message of a session can fail while
  /// both sides are still building sessions at the same moment
  /// (simultaneous initiation), and the one-time pre-key is only
  /// consumed on a successful decrypt, so a later retry still
  /// succeeds (verified by test). Failed rows therefore stay pending
  /// while their bounded retry budget remains ([signalDecryptShouldRetry])
  /// and only then move to [_decryptFailed] (tap-to-retry) — never to
  /// [_permanentlyUnreadable]. Rows are left pending (not failed) when
  /// Signal is not initialised yet or the sender's devices are
  /// unknown, so a later retry can still heal them. A second pass runs
  /// when the first pass decrypted something (the session healed
  /// mid-batch), so a race-failed first message is retried at once.
  /// Never throws.
  Future<void> _decryptSignalRows(
    List<Map<String, dynamic>> rows,
  ) async {
    var sync = _signalSync;
    if (sync == null) {
      await _initSignal();
      sync = _signalSync;
      if (sync == null || !mounted) return;
    }
    if (!_membersLoaded) {
      await _loadMembers(silent: true);
      if (!mounted) return;
    }
    final myId = client.auth.currentUser?.id;
    _decryptRunning = true;
    var changed = false;
    var pending = rows;
    // Peers healed in this run (at most one heal per peer per run).
    final healedPeers = <String>{};
    for (var pass = 0; pass < 2 && pending.isNotEmpty; pass++) {
      final nextPending = <Map<String, dynamic>>[];
      var anySuccess = false;
      for (final row in pending) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        // Own Signal rows are never decrypted (the sender cannot
        // decrypt their own outgoing ciphertext) — belt and braces
        // alongside the routing skip in _decryptPendingRows.
        final senderId = row['sender_id']?.toString() ?? '';
        if (myId != null && senderId == myId) continue;
        _decrypting.add(id);
        try {
          final ciphertext = row['ciphertext']?.toString() ?? '';
          final type = parseSignalMsgType(
            row['signal_msg_type']?.toString(),
          );
          if (senderId.isEmpty || ciphertext.isEmpty || type == null) {
            // Missing data in the row itself, not a transient
            // failure: it can never decrypt.
            _permanentlyUnreadable.add(id);
            changed = true;
            continue;
          }
          final isPreKey = type == CiphertextMessageType.preKey;
          String? plain;
          var triedAnyDevice = false;
          for (final deviceUuid in _memberDeviceUuids(senderId)) {
            triedAnyDevice = true;
            plain = await sync.decryptFrom(
              senderId,
              deviceUuid,
              ciphertext,
              isPreKey,
            );
            if (plain != null) break;
          }
          if (plain != null) {
            _decrypted[id] = plain;
            // Prune the persistent attempt record: the row healed.
            await sync.decryptAttempts.clear(id);
            await sync.decryptAttempts.clearHealed(id);
            anySuccess = true;
            changed = true;
          } else if (triedAnyDevice) {
            // Every known sender device failed: usually a transient
            // race (session still converging). Bounded retry — leave
            // pending while attempts remain, then failed (retryable)
            // with one automatic session heal.
            await _recordSignalDecryptFailure(
              id,
              nextPending,
              row,
              senderId,
              healedPeers,
            );
            changed = true;
          }
          // No known sender device at all: leave the row pending (do
          // not mark it) — a later members load may still heal it.
        } catch (_) {
          await _recordSignalDecryptFailure(
            id,
            nextPending,
            row,
            senderId,
            healedPeers,
          );
          changed = true;
        } finally {
          _decrypting.remove(id);
        }
      }
      if (!anySuccess) break;
      pending = nextPending;
    }
    _decryptRunning = false;
    if (changed && mounted) setState(() {});
  }

  /// Records one failed Signal decrypt attempt for [id] in the
  /// persistent store, and either leaves the row pending for the
  /// next decrypt pass (added to [nextPending]) or, once the budget
  /// is spent, marks it failed (tap-to-retry) and heals the session
  /// for [senderId] once (unless this row already healed it, or a
  /// peer in [healedPeers] was already healed in this run).
  /// Never permanently unreadable: the row itself stays
  /// undecryptable (it was encrypted under the lost session), but
  /// the heal is for NEW messages.
  Future<void> _recordSignalDecryptFailure(
    String id,
    List<Map<String, dynamic>> nextPending,
    Map<String, dynamic> row,
    String senderId,
    Set<String> healedPeers,
  ) async {
    final sync = _signalSync;
    if (sync == null) {
      // No Signal sync (should not happen — the caller checked):
      // leave pending, never failed.
      nextPending.add(row);
      return;
    }
    final attempts = await sync.decryptAttempts.recordAttempt(id);
    if (signalDecryptShouldRetry(attempts)) {
      nextPending.add(row);
      return;
    }
    _decryptFailed.add(id);
    // Budget spent: the session is desynced, not merely converging.
    // Heal it once (for new messages), unless this row already did.
    final wasHealed = await sync.decryptAttempts.wasHealed(id);
    if (!shouldHealSessionAfterFailure(
      attempts: attempts,
      wasHealed: wasHealed,
    )) {
      return;
    }
    var healed = false;
    for (final deviceUuid in _memberDeviceUuids(senderId)) {
      final peerKey = '$senderId::$deviceUuid';
      if (healedPeers.contains(peerKey)) continue;
      healedPeers.add(peerKey);
      if (await sync.healSessionFor(senderId, deviceUuid)) {
        healed = true;
      }
    }
    if (healed) {
      await sync.decryptAttempts.markHealed(id);
      if (mounted) setState(() => _signalSessionReady = true);
    }
  }

  /// Tap-to-retry for rows that definitively failed to decrypt:
  /// clears the failed set and the persistent attempt/heal records,
  /// rebuilds the Signal session for the 1:1 peer (the retry heals
  /// the session, not just re-tries the same broken one), then
  /// re-runs the key load and decryption. If the key is still
  /// blocked, the rows fail again — the retry is honest, never a
  /// silent spin back to "جارٍ فك التشفير…". Permanently unreadable
  /// rows (fix 5) have no retry link, so they are never cleared here.
  /// Signal rows are re-decrypted directly as well (they need no old
  /// conversation key).
  Future<void> _retryDecryption() async {
    if (!mounted) return;
    final failedIds = _decryptFailed.toList();
    final sync = _signalSync;
    final otherId = _otherUserId;
    setState(() {
      _decryptFailed.clear();
      _keyDefinitivelyBlocked = false;
      _keyLoadNullCount = 0;
    });
    // Clear the persistent attempt/heal records so the failed rows
    // get a fresh budget, and rebuild the session for the peer so
    // the retry runs against a fresh session.
    if (sync != null) {
      for (final id in failedIds) {
        await sync.decryptAttempts.clear(id);
        await sync.decryptAttempts.clearHealed(id);
      }
      if (otherId != null) {
        for (final deviceUuid in _memberDeviceUuids(otherId)) {
          if (await sync.healSessionFor(otherId, deviceUuid)) {
            if (mounted) setState(() => _signalSessionReady = true);
          }
        }
      }
    }
    _ensureConversationKey();
    unawaited(_decryptPendingRows(_lastRows));
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    if (extent > 0) _scroll.jumpTo(extent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    currentOpenConversationId.value = null;
    _keyRetryTimer?.cancel();
    _stopFallbackPoll();
    input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // -- Mute (F42, chat side) ---------------------------------------------
  // muted_until lives on the current user's profile row. The column only
  // exists once the backend migration is applied; a missing column (or
  // any other fetch failure) is treated as "not muted", never a crash.

  Future<void> _loadMutedUntil() async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) {
      _mutedLoaded = true;
      return;
    }
    try {
      final row = await client
          .from('profiles')
          .select('muted_until')
          .eq('id', uid)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));
      final raw = row?['muted_until']?.toString();
      _mutedUntil =
          raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
    } catch (_) {
      _mutedUntil = null;
    } finally {
      _mutedLoaded = true;
    }
  }

  Future<bool> _isMuted() async {
    if (!_mutedLoaded) await _loadMutedUntil();
    final until = _mutedUntil;
    if (until == null) return false;
    return until.isAfter(DateTime.now());
  }

  String get _mutedMessage {
    final until = _mutedUntil;
    if (until == null) return 'تم كتمك.';
    return 'تم كتمك حتى ${DateFormat('dd/MM/yyyy HH:mm').format(until.toLocal())}';
  }

  Future<void> _refreshMutedAfterForbidden() async {
    _mutedLoaded = false;
    await _loadMutedUntil();
  }

  void _showSessionExpired() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('انتهت الجلسة. سجّل الدخول مجدداً.')),
    );
  }

  String? _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'zip':
        return 'application/zip';
      default:
        return null;
    }
  }

  /// Only channel admins may post; the RLS policy enforces this
  /// server-side, this guard is UX so a member never opens the picker
  /// or sends into a rejection. The role comes from the caller
  /// (ChatPage.isAdmin now defaults to false).
  bool get _canPost =>
      canPostInConversation(widget.kind, widget.isAdmin ? 'admin' : 'member');

  /// Persistent plaintext banner (F38): shown whenever this conversation
  /// is currently sending plaintext — no key, or not every member has a
  /// public key. Subtle and non-blocking, above the composer.
  ///
  /// 1:1 chats use the Signal Protocol, not the old conversation key,
  /// so their banner is driven by Signal session readiness instead:
  /// it shows only while no Signal session exists for the other
  /// member. Group chats keep the old-E2E condition.
  bool get _showPlaintextBanner {
    if (!_membersLoaded) return false;
    if (_isDirectChat) return !_signalSessionReady;
    return _conversationKey == null || !canEncryptFor(_memberDeviceKeys);
  }

  /// True for a 1:1 direct chat (exactly two members, direct kind):
  /// the only chats that use the Signal Protocol. Groups and channels
  /// keep the old E2E path.
  bool get _isDirectChat =>
      widget.kind == 'direct' && !_isGroup && _memberIds.length == 2;

  /// The banner text: names the real cause (missing member key vs.
  /// key-load failure) instead of always blaming a member key.
  String get _plaintextBannerMessage =>
      plaintextBannerMessage(_memberDeviceKeys);

  void _showReadOnlyNote() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('النشر في هذه القناة للمشرفين فقط')),
    );
  }

  /// The other participant of a direct chat, if known. Groups and channels
  /// have no single "other user", so user reporting is direct-only.
  String? get _otherUserId {
    final myId = client.auth.currentUser?.id;
    for (final id in _memberIds) {
      if (id != myId) return id;
    }
    return null;
  }

  /// Starts a voice or video call to the other participant of a direct
  /// chat. Calls are peer-to-peer and 1:1, so the buttons only exist for
  /// direct chats (see the AppBar below).
  Future<void> _startCall(String callType) async {
    final otherId = _otherUserId;
    if (otherId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذّر بدء المكالمة. بيانات الأعضاء غير جاهزة بعد.')),
        );
      }
      return;
    }
    if (_startingCall) return;
    _startingCall = true;
    if (mounted) setState(() {});
    final otherName = _memberNames[otherId] ?? widget.title;
    try {
      final callId = await CallService.instance.startCall(
          calleeId: otherId, calleeName: otherName, callType: callType);
      if (callId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'تعذّر بدء المكالمة. تحقق من أذونات الميكروفون والكاميرا.')),
          );
        }
        return;
      }
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => CallPage(
                  callId: callId,
                  peerId: otherId,
                  peerName: otherName,
                  callType: callType,
                  isCaller: true)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذّر بدء المكالمة. تحقق من الاتصال وحاول مجدداً.')),
        );
      }
    } finally {
      _startingCall = false;
      if (mounted) setState(() {});
    }
  }

  /// Leaves this group/channel. Calls the `leave_conversation` RPC
  /// (params: {'p_conversation_id': a UUID}) — that RPC is being added
  /// by the backend coordinator; if it is not deployed yet the error is
  /// shown in a snackbar instead of crashing. On success, pops the page.
  Future<void> _leaveConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.kind == 'channel'
            ? 'مغادرة القناة؟'
            : 'مغادرة المجموعة؟'),
        content: Text(widget.kind == 'channel'
            ? 'ستغادر هذه القناة ولن تصلك رسائلها بعد الآن.'
            : 'ستغادر هذه المجموعة ولن تصلك رسائلها بعد الآن.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('مغادرة')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await client
          .rpc('leave_conversation',
              params: {'p_conversation_id': widget.conversationId})
          .timeout(const Duration(seconds: 20));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'تعذر مغادرة ${widget.kind == 'channel' ? 'القناة' : 'المجموعة'}. ${networkErrorMessage(e) ?? e.toString()}')),
        );
      }
    }
  }

  /// Members sheet for groups/channels, from the already-loaded member
  /// data. Admins see a remove button for other members (never for
  /// themselves); removal calls the `remove_member` RPC (params:
  /// {'p_conversation_id': a UUID, 'p_target_user': a UUID}).
  Future<void> _showMembersSheet() async {
    final myId = client.auth.currentUser?.id;
    await showModalBottomSheet(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final ids = _memberIds.toList();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    const Icon(Icons.group_outlined),
                    const SizedBox(width: 8),
                    Text('الأعضاء (${ids.length})',
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: ids.map((id) {
                        final name = _memberNames[id] ?? 'مستخدم';
                        final isMe = id == myId;
                        return ListTile(
                          leading: const CircleAvatar(
                              child: Icon(Icons.person)),
                          title: Text(name),
                          subtitle: isMe ? const Text('أنت') : null,
                          trailing: widget.isAdmin && !isMe
                              ? TextButton(
                                  onPressed: () async {
                                    try {
                                      await client.rpc('remove_member',
                                          params: {
                                            'p_conversation_id':
                                                widget.conversationId,
                                            'p_target_user': id,
                                          }).timeout(
                                          const Duration(seconds: 20));
                                      await _loadMembers(silent: true);
                                      setSheetState(() {});
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                              content: Text(
                                                  'تمت إزالة العضو.')),
                                        );
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                              content: Text(
                                                  'تعذرت إزالة العضو. ${networkErrorMessage(e) ?? e.toString()}')),
                                        );
                                      }
                                    }
                                  },
                                  child: const Text('إزالة'),
                                )
                              : null,
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// One shared report dialog for messages and users: preset reason chips
  /// plus a free-text field when "أخرى" is chosen.
  Future<void> _showReportDialog({
    required String targetType,
    required String targetId,
    required String title,
  }) async {
    const reasons = ['محتوى مسيء', 'إزعاج', 'أخرى'];
    var selected = reasons.first;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                children: reasons
                    .map((reason) => ChoiceChip(
                          label: Text(reason),
                          selected: selected == reason,
                          onSelected: (_) =>
                              setDialogState(() => selected = reason),
                        ))
                    .toList(),
              ),
              if (selected == 'أخرى') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  decoration: const InputDecoration(
                      labelText: 'سبب البلاغ',
                      border: OutlineInputBorder()),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('إرسال البلاغ')),
          ],
        ),
      ),
    );
    final otherReason = reasonController.text.trim();
    reasonController.dispose();
    if (confirmed != true) return;
    final reason = selected == 'أخرى' ? otherReason : selected;
    try {
      await submitReport(
          targetType: targetType,
          targetId: targetId,
          reason: reason.isEmpty ? 'أخرى' : reason);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال البلاغ. شكراً لك.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذر إرسال البلاغ. تحقق من الاتصال وحاول مجدداً.')),
        );
      }
    }
  }

  /// Confirm dialog for resetting this conversation's encryption, then
  /// the reset itself. The reset is the recovery when the conversation
  /// key is truly lost (a wrapped row that unwraps with neither KEK):
  /// the server deletes every wrapped row for this conversation and
  /// this device creates a fresh key. Old encrypted messages in this
  /// conversation stay unreadable FOREVER — the dialog says so
  /// plainly — and new messages use the fresh key. Best-effort
  /// errors show a snackbar, never a crash.
  Future<void> _showResetEncryptionDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إعادة تعيين التشفير'),
        content: const Text(
            'سيتم حذف مفاتيح التشفير الحالية لهذه المحادثة وإنشاء مفتاح '
            'جديد. الرسائل المشفّرة القديمة في هذه المحادثة ستبقى غير '
            'قابلة للقراءة للأبد، وستُشفَّر الرسائل الجديدة بالمفتاح '
            'الجديد. هل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('إعادة تعيين')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _resetEncryption();
  }

  /// The reset itself. The reset is the recovery when the conversation
  /// key is truly lost (a wrapped row that unwraps with neither KEK):
  /// the server deletes every wrapped row for this conversation and
  /// this device creates a fresh key. Old encrypted messages in this
  /// conversation stay unreadable FOREVER — the dialog says so
  /// plainly — and new messages use the fresh key.
  ///
  /// Signal (1:1 chats): the reset button is KEPT, and for a 1:1 chat
  /// it also deletes this device's Signal session(s) for the other
  /// member, so the next send establishes a FRESH session from the
  /// peer's current bundle (the Signal equivalent of a reset). The old
  /// conversation-key reset above still runs (it only affects old-E2E
  /// rows and groups); for 1:1 chats new messages use Signal, so the
  /// old-key part is effectively a no-op for them. Old Signal messages
  /// stay readable (their session is gone, but the Double Ratchet
  /// state for already-decrypted messages lives in the stores and the
  /// rows themselves are untouched) — unlike the old path, a Signal
  /// reset does NOT orphan history.
  ///
  /// Fix 1: the reset NEVER silently creates a partial key again. The
  /// order matters: (1) load FRESH member keys and ABORT — before the
  /// RPC deletes anything — when a member has no usable key yet (the
  /// 19:10 reset wrapped for a stale member map, before the second
  /// phone's device key had registered, and produced a key only one
  /// side could use; aborting after the delete would leave the
  /// conversation keyless with no way back, because the
  /// encrypted-messages guard blocks a fresh key without another
  /// reset); (2) delete the old rows; (3) await the fresh key load
  /// (fix 3 — the reset's load used to be dropped when another load
  /// was in flight); (4) warn when the creation wrap wrote no row for
  /// some member. Best-effort errors show a snackbar, never a crash.
  Future<void> _resetEncryption() async {
    // (1) Fresh member keys first. A failed load aborts the reset: the
    // member map may be stale, and wrapping from it could poison the
    // fresh key.
    await _loadMembers(silent: true);
    if (!mounted) return;
    if (_membersError || _memberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تعذّر تحميل بيانات الأعضاء — تحقق من الاتصال وحاول مجدداً. لم يتم حذف أي مفتاح.')),
      );
      return;
    }
    final missing = membersMissingKeys(_memberIds, _memberDeviceKeys);
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'لم تكتمل إعادة التعيين: بعض الأعضاء بلا مفتاح تشفير بعد. افتح المحادثة على هواتفهم ثم أعد المحاولة. لم يتم حذف أي مفتاح.')),
      );
      return;
    }
    // (2) Delete the old rows.
    try {
      await client.rpc('reset_conversation_keys', params: {
        'p_conversation_id': widget.conversationId,
      }).timeout(const Duration(seconds: 20));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'تعذّرت إعادة تعيين التشفير. ${networkErrorMessage(e) ?? e.toString()}')),
        );
      }
      return;
    }
    if (!mounted) return;
    // The old key is gone: drop every cached decrypt product of it
    // (showing them would display text the new key cannot produce)
    // and reload with afterReset so a fresh key is created even though
    // encrypted messages exist. Malformed rows are NOT cleared: they
    // are about the row format, not the key. The generation bump makes
    // any load that started before the reset discard its result (fix 3).
    _keyLoadGeneration++;
    // Capture the failed row ids before clearing the in-memory set,
    // so their persistent attempt/heal records can be cleared too.
    final failedRowIds = _decryptFailed.toList();
    setState(() {
      _conversationKey = null;
      _conversationKeyLoaded = false;
      _keyDefinitivelyBlocked = false;
      _keyLoadNullCount = 0;
      _lastWrapUncovered = {};
      _decrypted.clear();
      _decryptFailed.clear();
      _permanentlyUnreadable.clear();
    });
    // Clear the persistent decrypt-attempt/heal records for this
    // conversation's rows, so the reset gives them a fresh budget
    // against the rebuilt session.
    final resetSync = _signalSync;
    if (resetSync != null) {
      final resetIds = <String>{
        ...failedRowIds,
        ..._lastRows.map((r) => r['id']?.toString() ?? ''),
      }..remove('');
      for (final id in resetIds) {
        await resetSync.decryptAttempts.clear(id);
        await resetSync.decryptAttempts.clearHealed(id);
      }
    }
    // (3) Await the fresh key load — never fire-and-forget it.
    await _ensureConversationKey(afterReset: true);
    if (!mounted) return;
    // (4) Report the outcome. NOTE on the read-back: conversation_keys
    // SELECT is own-rows-only (migration 012), so other members' rows
    // cannot be read back from the client — the wrap's own outcome
    // (_lastWrapUncovered, from wrapKeyForMembers) is the coverage
    // signal instead. A null key means the load itself failed.
    if (_conversationKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تم حذف المفاتيح القديمة لكن تعذّر إنشاء مفتاح جديد — تحقق من الاتصال وأعد فتح المحادثة.')),
      );
    } else if (_lastWrapUncovered.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تمت إعادة تعيين التشفير لكن بعض الأعضاء بلا مفتاح بعد — افتح المحادثة على هواتفهم ثم أعد المحاولة.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تمت إعادة تعيين التشفير. الرسائل الجديدة ستُشفَّر.')),
      );
    }
    // Signal (1:1): also delete this device's Signal session(s) for
    // the other member, so the next send establishes a fresh session
    // from the peer's current bundle. Best-effort; the old-key reset
    // above already reported its outcome.
    if (_isDirectChat) {
      final sync = _signalSync;
      final otherId = _otherUserId;
      if (sync != null && otherId != null) {
        for (final deviceUuid in _memberDeviceUuids(otherId)) {
          await sync.resetSessionFor(otherId, deviceUuid);
        }
        if (mounted) {
          setState(() => _signalSessionReady = false);
        }
      }
    }
  }

  /// Long-press on a message bubble: offer to report that message.
  void _showMessageActions(Map<String, dynamic> row) {
    final messageId = row['id']?.toString() ?? '';
    if (messageId.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('الإبلاغ عن هذه الرسالة'),
          onTap: () {
            Navigator.pop(context);
            _showReportDialog(
                targetType: 'message',
                targetId: messageId,
                title: 'الإبلاغ عن هذه الرسالة');
          },
        ),
      ),
    );
  }

  /// One-time-per-session confirmation before a plaintext downgrade:
  /// only shown when this conversation already has encrypted messages
  /// (so the user is losing encryption they had) and no key is in hand.
  Future<bool> _confirmPlaintextSend() async {
    if (_plaintextDowngradeWarned) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إرسال غير مشفّر؟'),
        content: const Text(
            'لا يوجد مفتاح تشفير لهذه المحادثة بعد، وستُرسل هذه الرسالة غير مشفّرة ويمكن قراءتها.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('إرسال غير مشفّرة')),
        ],
      ),
    );
    if (ok == true) {
      _plaintextDowngradeWarned = true;
      return true;
    }
    return false;
  }

  Future<void> sendAttachment() async {
    if (!_canPost) {
      _showReadOnlyNote();
      return;
    }
    if (sending) return;
    final uid = client.auth.currentUser?.id;
    if (uid == null) {
      _showSessionExpired();
      return;
    }
    if (await _isMuted()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_mutedMessage)),
        );
      }
      return;
    }
    String? uploadedPath;
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final mime = _mimeFor(file.extension ?? '');
      if (mime == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'نوع الملف غير مدعوم. اختر صورة أو فيديو أو صوتاً أو PDF أو TXT أو ZIP.')),
          );
        }
        return;
      }
      const maxBytes = 50 * 1024 * 1024;
      if (file.size <= 0 || file.size > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'يجب أن يكون حجم الملف أكبر من صفر ولا يتجاوز 50 ميغابايت.')),
          );
        }
        return;
      }
      final filePath = file.path;
      if (filePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر الوصول إلى الملف المحدد.')),
          );
        }
        return;
      }
      setState(() => sending = true);
      // Upload the file itself instead of reading up to 50 MB into memory
      // first; the old code held the whole file in RAM as bytes.
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path =
          '${widget.conversationId}/$uid/${DateTime.now().microsecondsSinceEpoch}_$safeName';
      await client.storage.from('helba-chat-media').upload(
            path,
            io.File(filePath),
            fileOptions: FileOptions(contentType: mime, upsert: false),
          );
      uploadedPath = path;
      final type = mime.startsWith('image/')
          ? 'image'
          : mime.startsWith('video/')
              ? 'video'
              : mime.startsWith('audio/')
                  ? 'audio'
                  : 'file';
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': file.name,
        'message_type': type,
        'attachment_path': path,
      });
      uploadedPath = null;
    } catch (e) {
      if (e.toString().contains('403')) await _refreshMutedAfterForbidden();
      if (uploadedPath != null) {
        try {
          await client.storage
              .from('helba-chat-media')
              .remove([uploadedPath]);
        } catch (_) {
          // Keep the original upload error; an orphan can be cleaned up later.
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذر رفع الملف. تحقق من الاتصال ونوع الملف.')),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> openAttachment(String path) async {
    try {
      final url = await client.storage
          .from('helba-chat-media')
          .createSignedUrl(path, 300);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح المرفق أو انتهت صلاحيته.')),
        );
      }
    }
  }

  /// Renders a text message body with its encryption state.
  /// Attachments are handled by the caller (files are NOT E2E-encrypted).
  /// The branch is decided by the pure [encryptedRowBody] helper; this
  /// widget only renders the decision.
  Widget _messageBody(Map<String, dynamic> row) {
    const labelStyle = TextStyle(fontSize: 10, color: Colors.black54);
    if (isEncryptedMessage(row)) {
      final id = row['id']?.toString() ?? '';
      switch (encryptedRowBody(
        row: row,
        currentUserId: client.auth.currentUser?.id,
        decrypted: _decrypted,
        ownSentPlaintext: _ownSentPlaintext,
        malformedIds: _malformedIds,
        permanentlyUnreadable: _permanentlyUnreadable,
        decryptFailed: _decryptFailed,
      )) {
        case EncryptedRowBody.decrypted:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_decrypted[id]!),
              const Text('🔒 مشفّرة', style: labelStyle),
            ],
          );
        case EncryptedRowBody.ownPlaintext:
          // Own sent Signal message: shown from the plaintext stored
          // on this device at send time — never re-decrypted.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_ownSentPlaintext[id]!),
              const Text('🔒 مشفّرة', style: labelStyle),
            ],
          );
        case EncryptedRowBody.ownPlaceholder:
          // Own sent Signal message with no stored plaintext (sent
          // from another device / local storage cleared): the
          // placeholder, still with the encrypted label — never a
          // decryption failure.
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(encryptedMessagePlaceholder),
              Text('🔒 مشفّرة', style: labelStyle),
            ],
          );
        case EncryptedRowBody.malformed:
          return const Text('رسالة تالفة');
        case EncryptedRowBody.permanentlyUnreadable:
          // Fix 5: the ciphertext was encrypted under a key that is
          // gone for good (lost on reinstall / deleted by a reset).
          // Label it permanently unreadable — with NO retry link,
          // because no retry can ever succeed — and never show the
          // "جارٍ فك التشفير…" spinner for it again. Signal rows
          // never reach this state (bounded retry, then failed).
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('تعذّر فك تشفير هذه الرسالة نهائياً'),
              Text('فُقد مفتاح تشفيرها ولا يمكن استرجاعها.',
                  style: labelStyle),
            ],
          );
        case EncryptedRowBody.failed:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تعذّر فك تشفير هذه الرسالة'),
              const Text(
                'أعد المحاولة لإعادة بناء التشفير.',
                style: labelStyle,
              ),
              const SizedBox(height: 2),
              GestureDetector(
                onTap: _retryDecryption,
                child: const Text(
                  'إعادة المحاولة',
                  style: TextStyle(
                      fontSize: 10,
                      color: Colors.blue,
                      decoration: TextDecoration.underline),
                ),
              ),
            ],
          );
        case EncryptedRowBody.decrypting:
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(encryptedMessagePlaceholder),
              Text('جارٍ فك التشفير…', style: labelStyle),
            ],
          );
      }
    }
    // Plaintext message: show the body with a visible "not encrypted"
    // note, so the fallback is never silent. (System messages excluded.)
    if (row['message_type'] == 'system') {
      return Text(row['body']?.toString() ?? '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(row['body']?.toString() ?? ''),
        const Text('🔓 غير مشفّرة', style: labelStyle),
      ],
    );
  }

  /// Sends [body] as a Signal Protocol message in a 1:1 chat. Tries
  /// each of the other member's devices in order (the recipient need
  /// not be online — the session is built from their published bundle)
  /// and stores the first successful encryption as a Signal row:
  /// `ciphertext` = base64 Signal ciphertext, `signal_msg_type` =
  /// 'prekey' (first message on a fresh session) or 'signal',
  /// `nonce` intentionally NULL (the nonce lives inside the serialized
  /// Signal ciphertext — NULL is also what distinguishes Signal rows
  /// from old-E2E rows). Returns true when a Signal row was stored,
  /// false when no session could be established (no bundle, no
  /// devices, Signal unavailable) — the caller then falls back to
  /// plaintext. Never throws.
  ///
  /// The plaintext is also stored ON-DEVICE ONLY (see
  /// [SentSignalPlaintextStore]) under the inserted row's id, so this
  /// device can show its own sent message: a Signal sender cannot
  /// decrypt their own outgoing ciphertext. The server only ever
  /// holds the placeholder body + ciphertext.
  Future<bool> _trySendViaSignal(String body, String uid) async {
    final sync = _signalSync;
    final otherId = _otherUserId;
    if (sync == null || otherId == null) return false;
    try {
      if (!_membersLoaded) await _loadMembers(silent: true);
      for (final deviceUuid in _memberDeviceUuids(otherId)) {
        final result = await sync.encryptFor(otherId, deviceUuid, body);
        if (result == null) continue;
        final inserted = await client
            .from('messages')
            .insert({
              'conversation_id': widget.conversationId,
              'sender_id': uid,
              'body': encryptedMessagePlaceholder,
              'message_type': 'text',
              'is_encrypted': true,
              'ciphertext': result.ciphertextBase64,
              'signal_msg_type': result.isPreKeyMessage
                  ? signalMsgTypePreKey
                  : signalMsgTypeSignal,
            })
            .select('id')
            .single();
        final messageId = inserted['id']?.toString() ?? '';
        if (messageId.isNotEmpty) {
          _ownSentPlaintext[messageId] = body;
          try {
            await sync.sentPlaintexts.save(messageId, body);
          } catch (_) {
            // Best-effort: the in-memory copy still shows it this
            // session; the next reload falls back to the placeholder.
          }
        }
        if (mounted) {
          setState(() => _signalSessionReady = true);
        }
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> send() async {
    if (!_canPost) {
      _showReadOnlyNote();
      return;
    }
    final body = input.text.trim();
    final uid = client.auth.currentUser?.id;
    if (uid == null) {
      _showSessionExpired();
      return;
    }
    if (body.isEmpty || sending) return;
    if (body.length > 4000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحد الأقصى للرسالة 4000 حرف.')),
      );
      return;
    }
    if (await _isMuted()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_mutedMessage)),
        );
      }
      return;
    }
    setState(() => sending = true);
    try {
      // Signal 1:1 (new): in a direct (1:1) conversation, encrypt with
      // the Signal Protocol instead of the old conversation key. The
      // recipient need not be online — the session is built from their
      // published pre-key bundle. On success the message is stored as
      // a Signal row and we return. On failure (no bundle / no
      // session) we fall through to PLAINTEXT — never to the old E2E
      // path, which is retired for 1:1 chats. Group chats skip this
      // block and keep the old E2E path below.
      if (_isDirectChat) {
        if (await _trySendViaSignal(body, uid)) {
          input.clear();
          return;
        }
        final hadEncrypted =
            _lastRows.any((row) => isEncryptedMessage(row));
        if (hadEncrypted && !await _confirmPlaintextSend()) return;
        await client.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': uid,
          'body': body,
          'message_type': 'text',
        });
        input.clear();
        return;
      }
      // E2E (best-effort, never blocks sending): make sure I have a
      // keypair and a published public key, refresh members' keys, then
      // load/create the conversation key and lazily wrap it for any
      // member who has a public key now but no wrapped row yet. Only
      // when the key exists AND every member has a public key does the
      // text go out encrypted; otherwise it goes out as plaintext, and
      // the reader labels it '🔓 غير مشفّرة' so the fallback is visible.
      List<int>? convKey;
      var canEncrypt = false;
      try {
        final pair = await ensureKeyPair();
        try {
          // Fix 4: a failed/unverified publish warns the user (once
          // per session) instead of being swallowed.
          final published = await publishPublicKeyIfNeeded(pair: pair);
          if (!published) _warnPublishFailed();
        } catch (_) {
          // Publishing must never block sending.
        }
        await _loadMembers(silent: true);
        final loadedKey = await loadOrCreateConversationKey(
            widget.conversationId, _memberDeviceKeys);
        convKey = loadedKey.key;
        if (convKey != null) {
          Set<String> uncovered = {};
          try {
            uncovered = await wrapKeyForMembers(
                widget.conversationId, convKey, _memberDeviceKeys);
          } catch (_) {
            // Lazy re-wrap is best-effort; the message still goes out.
          }
          canEncrypt = canEncryptFor(_memberDeviceKeys);
          if (mounted) {
            setState(() {
              _conversationKey = convKey;
              _conversationKeyLoaded = true;
              // The key is in hand now: a previous definitive block no
              // longer applies, and the empty-load count resets.
              _keyDefinitivelyBlocked = false;
              _keyLoadNullCount = 0;
              _lastWrapUncovered = uncovered;
              _decryptFailed.clear();
            });
          }
        }
      } catch (_) {
        convKey = null;
      }
      if (convKey != null && canEncrypt) {
        final encrypted = await encryptText(body, convKey);
        await client.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': uid,
          'body': encryptedMessagePlaceholder,
          'message_type': 'text',
          'is_encrypted': true,
          'ciphertext': encrypted.ciphertext,
          'nonce': encrypted.nonce,
        });
      } else {
        // Plaintext downgrade: if this conversation already has
        // encrypted messages, warn once per session first instead of
        // silently sending plaintext.
        final hadEncrypted =
            _lastRows.any((row) => isEncryptedMessage(row));
        if (hadEncrypted && !await _confirmPlaintextSend()) return;
        await client.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': uid,
          'body': body,
          'message_type': 'text',
        });
      }
      input.clear();
    } catch (e) {
      if (e.toString().contains('403')) {
        await _refreshMutedAfterForbidden();
        if (await _isMuted()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_mutedMessage)),
            );
          }
          return;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر إرسال الرسالة.')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  /// The message list for a set of rows, with the decrypt/scroll
  /// post-frame work scheduled ONLY when the row count or the set of
  /// encrypted ids actually changed (M-9: not on every build).
  Widget _buildMessageList(List<Map<String, dynamic>> rows) {
    _lastRows = rows;
    final encryptedIds = rows
        .where((row) => isEncryptedMessage(row))
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final changed = rows.length != _lastMessageCount ||
        encryptedIds.length != _lastEncryptedIds.length ||
        !encryptedIds.containsAll(_lastEncryptedIds);
    if (changed) {
      _lastMessageCount = rows.length;
      _lastEncryptedIds = encryptedIds;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _maybeRetryKeyLoad();
          _decryptPendingRows(rows);
        }
      });
    }
    final list = RefreshIndicator(
      onRefresh: _refreshMessages,
      child: ListView.builder(
        controller: _scroll,
        // Always scrollable so pull-to-refresh works even when the
        // list is shorter than the viewport.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(14),
        itemCount: rows.length,
        itemBuilder: (context, i) {
        final row = rows[i];
        final myId = client.auth.currentUser?.id;
        final mine = myId != null && row['sender_id'] == myId;
        final senderName = _memberNames[row['sender_id']?.toString()];
        final time =
            DateTime.tryParse(row['created_at']?.toString() ?? '');
        return GestureDetector(
          onLongPress: () => _showMessageActions(row),
          child: Align(
            alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                  color: mine ? const Color(0xFFDDF3E6) : Colors.white,
                  borderRadius: BorderRadius.circular(16)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!mine &&
                        (_isGroup || isChannelKind(widget.kind)) &&
                        senderName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(senderName,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: green)),
                      ),
                    if (row['attachment_path'] != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            onTap: () => openAttachment(
                                row['attachment_path'].toString()),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.attach_file,
                                  size: 18, color: green),
                              const SizedBox(width: 5),
                              Flexible(
                                  child: Text(
                                      row['body']?.toString() ?? 'مرفق',
                                      style: const TextStyle(
                                          decoration:
                                              TextDecoration.underline))),
                              const SizedBox(width: 5),
                              const Icon(Icons.download_rounded,
                                  size: 17, color: green),
                            ]),
                          ),
                          const Text('🔓 غير مشفّرة',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.black54)),
                        ],
                      )
                    else
                      _messageBody(row),
                    if (time != null)
                      Text(formatChatTime(time),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.black54)),
                  ]),
            ),
          ),
        );
      },
      ),
    );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (!_validConversationId) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(
            child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('المحادثة غير موجودة أو لا يمكنك الوصول إليها.',
              textAlign: TextAlign.center),
        )),
      );
    }
    final isGroupOrChannel =
        widget.kind == 'group' || widget.kind == 'channel';
    return Scaffold(
      appBar: AppBar(
          actions: [
            // Voice/video calls are 1:1 only: direct chats get the buttons,
            // groups and channels get none. The buttons stay visible but
            // disabled until members have loaded and the other user is
            // known, so they are never dead-looking or silently absent.
            if (widget.kind == 'direct') ...[
              IconButton(
                tooltip: 'مكالمة صوتية',
                onPressed: (_otherUserId == null || _startingCall || _membersLoading)
                    ? null
                    : () => _startCall('voice'),
                icon: const Icon(Icons.call),
              ),
              IconButton(
                tooltip: 'مكالمة فيديو',
                onPressed: (_otherUserId == null || _startingCall || _membersLoading)
                    ? null
                    : () => _startCall('video'),
                icon: const Icon(Icons.videocam),
              ),
            ],
            if (_membersError)
              IconButton(
                tooltip: 'إعادة تحميل بيانات الأعضاء',
                onPressed: _retryMembers,
                icon: const Icon(Icons.refresh),
              ),
            PopupMenuButton<String>(
              tooltip: 'خيارات',
              enabled: widget.kind == 'direct'
                  ? _otherUserId != null
                  : true,
              onSelected: (value) {
                if (value == 'report_user' && _otherUserId != null) {
                  _showReportDialog(
                      targetType: 'user',
                      targetId: _otherUserId!,
                      title: 'الإبلاغ عن المستخدم');
                } else if (value == 'members') {
                  _showMembersSheet();
                } else if (value == 'leave') {
                  _leaveConversation();
                } else if (value == 'reset_e2ee') {
                  _showResetEncryptionDialog();
                }
              },
              itemBuilder: (_) {
                final items = <PopupMenuEntry<String>>[];
                if (widget.kind == 'direct') {
                  items.add(const PopupMenuItem(
                      value: 'report_user',
                      child: Text('الإبلاغ عن المستخدم')));
                }
                if (isGroupOrChannel) {
                  items.add(const PopupMenuItem(
                      value: 'members', child: Text('الأعضاء')));
                  items.add(PopupMenuItem(
                      value: 'leave',
                      child: Text(widget.kind == 'channel'
                          ? 'مغادرة القناة'
                          : 'مغادرة المجموعة')));
                }
                items.add(const PopupMenuItem(
                    value: 'reset_e2ee',
                    child: Text('إعادة تعيين التشفير')));
                return items;
              },
            ),
          ],
          title: Row(children: [
        if (isChannelKind(widget.kind))
          const Row(children: [
            Icon(Icons.campaign_rounded),
            SizedBox(width: 8),
          ]),
        Expanded(
            child: Text(widget.title,
                overflow: TextOverflow.ellipsis, maxLines: 1)),
        if (isChannelKind(widget.kind))
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
                color: const Color(0xFFE1F1E8),
                borderRadius: BorderRadius.circular(10)),
            child: const Text('قناة',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: green)),
          ),
      ])),
      body: Column(children: [
        if (_membersError)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFFFFF3CD),
            child: Row(children: [
              const Expanded(
                  child: Text(
                      'تعذر تحميل بيانات الأعضاء — المكالمات والإبلاغ غير متاحة مؤقتاً.',
                      style: TextStyle(fontSize: 12))),
              TextButton(
                  onPressed: _retryMembers,
                  child: const Text('إعادة المحاولة')),
            ]),
          ),
        Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _messagesStream,
          builder: (context, snap) {
            // Already-loaded messages win over a later stream error:
            // a Realtime failure must not wipe messages that arrived.
            if (snap.hasData) {
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const Center(
                    child: Text('ابدأ المحادثة برسالة ترحيب 👋'));
              }
              return _buildMessageList(rows);
            }
            if (snap.hasError) {
              if (_fallbackRows != null) {
                return _buildMessageList(_fallbackRows!);
              }
              if (!_fallbackLoading) {
                WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _loadFallbackMessages());
              }
              final message = networkErrorMessage(snap.error!) ??
                  'تعذر تحميل الرسائل: ${snap.error}';
              return Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(message, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: _retryMessages,
                          child: const Text('إعادة المحاولة')),
                    ]),
              ));
            }
            return const Center(child: CircularProgressIndicator());
          },
        )),
        if (_showPlaintextBanner)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFFFFF3CD),
            child: Text(
                _plaintextBannerMessage,
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.center),
          ),
        SafeArea(
            child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: _canPost
              ? Row(children: [
            IconButton(
              tooltip: 'إرفاق ملف',
              onPressed: sending ? null : sendAttachment,
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(
                child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                        hintText: 'اكتب رسالة...',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none)))),
            const SizedBox(width: 8),
            IconButton.filled(
                onPressed: sending ? null : send,
                icon: const Icon(Icons.send),
                style: IconButton.styleFrom(
                    backgroundColor: green, foregroundColor: Colors.white)),
          ])
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.campaign_outlined, color: Colors.black54),
                    SizedBox(width: 8),
                    Text('النشر في هذه القناة للمشرفين فقط',
                        style: TextStyle(color: Colors.black54)),
                  ],
                ),
        )),
      ]),
    );
  }
}
