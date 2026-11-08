import 'dart:async';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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

// NOTE (encryption removed): kept for the unit tests in
// test/chat_inbox_helpers_test.dart; the chat no longer shows a
// plaintext banner.
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
        ? 'لم يتم تحميل مفتاح التشفير بعد'
        : 'أحد الأعضاء بلا مفتاح تشفير';

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

/// Empty key loads after which pending encrypted rows stop waiting
/// for decryption and are marked failed (retryable) instead
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
  bool _membersLoading = true;
  bool _membersError = false;


  // Double-tap guard for _startCall (the service-level guard is in
  // calls.dart, not here).
  bool _startingCall = false;

  // Mute state, cached per ChatPage session (F42). Loaded once in
  // initState; a missing muted_until column (backend migration not yet
  // applied) is treated as "not muted", never a crash.
  DateTime? _mutedUntil;
  bool _mutedLoaded = false;


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
  }

  Future<void> _initChat() async {
    // Encryption is permanently removed: loading the members is all
    // the chat needs — no Signal session, no conversation key.
    await _loadMembers();
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
  /// Newly arrived rows appear via the existing [_buildMessageList]
  /// path when the rows change.
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
  /// (Encryption is removed, so no member keys are loaded here any
  /// more.) On failure the error is surfaced (snackbar + retry
  /// affordance in the AppBar/body) instead of swallowed: with no
  /// members, call buttons and the report menu would silently
  /// disappear.
  Future<void> _loadMembers({bool silent = false}) async {
    if (mounted) setState(() => _membersLoading = true);
    try {
      final rows = await client.from('conversation_members')
          .select('user_id,profiles(display_name,username)')
          .eq('conversation_id', widget.conversationId)
          .timeout(const Duration(seconds: 15));
      final names = <String, String>{};
      final ids = <String>{};
      for (final row in rows) {
        ids.add(row['user_id'].toString());
        final profile = row['profiles'] as Map<String, dynamic>?;
        final name = profile?['display_name']?.toString().trim().isNotEmpty == true
            ? profile!['display_name'].toString()
            : (profile?['username']?.toString().isNotEmpty == true
                ? '@${profile!['username']}'
                : '');
        if (name.isNotEmpty) names[row['user_id'].toString()] = name;
      }
      if (mounted) {
        setState(() {
          _memberNames = names;
          _memberIds
            ..clear()
            ..addAll(ids);
          // Group = more than two member ids, not more than two
          // non-empty display names (M-1).
          _isGroup = ids.length > 2;
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

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    if (extent > 0) _scroll.jumpTo(extent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    currentOpenConversationId.value = null;
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

  /// Renders a message body. Encryption is permanently removed: an
  /// old encrypted row shows only the encrypted placeholder (it can
  /// never be decrypted), and a plaintext row shows just its body.
  Widget _messageBody(Map<String, dynamic> row) {
    if (isEncryptedMessage(row)) {
      return const Text(encryptedMessagePlaceholder);
    }
    return Text(row['body']?.toString() ?? '');
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
      // Encryption is permanently removed: every message is sent as
      // plaintext, for 1:1 chats and groups alike. No session, key,
      // or encryption step runs here.
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': body,
        'message_type': 'text',
      });
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

  /// The message list for a set of rows, with the scroll-to-bottom
  /// post-frame work scheduled ONLY when the row count actually
  /// changed (M-9: not on every build).
  Widget _buildMessageList(List<Map<String, dynamic>> rows) {
    // No decryption work to schedule any more (encryption is
    // removed): only scroll to the bottom when new rows arrive.
    final changed = rows.length != _lastMessageCount;
    if (changed) {
      _lastMessageCount = rows.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
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
