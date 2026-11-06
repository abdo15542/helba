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
bool isMalformedEncryptedRow(Map<String, dynamic> row) {
  if (!isEncryptedMessage(row)) return false;
  final ciphertext = row['ciphertext']?.toString() ?? '';
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

class _ChatPageState extends State<ChatPage> {
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
  List<int>? _conversationKey;
  // True ONLY once a non-null key has actually been loaded. A null key
  // must not set this, otherwise the key load never retries.
  bool _conversationKeyLoaded = false;
  bool _keyLoading = false;
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
    await _loadMembers();
    if (!mounted) return;
    await _ensureConversationKey();
  }

  /// Recreates the message stream after a terminal stream error, and
  /// clears any plain-select fallback so live updates take over again.
  void _retryMessages() {
    if (!_validConversationId) return;
    setState(() {
      _messagesStream = _buildMessagesStream();
      _fallbackRows = null;
      _fallbackLoading = false;
    });
  }

  /// Plain-select fallback: used only when the Realtime stream has
  /// errored. Shows the messages with a "live updates disconnected"
  /// hint instead of a full error screen.
  Future<void> _loadFallbackMessages() async {
    if (_fallbackLoading || !_validConversationId) return;
    _fallbackLoading = true;
    try {
      final rows = await client
          .from('messages')
          .select()
          .eq('conversation_id', widget.conversationId)
          .order('created_at', ascending: true)
          .limit(200)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _fallbackRows = rows.cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Stay on the error screen; the retry button is still there.
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
  Future<void> _ensureConversationKey({bool afterReset = false}) async {
    if (_conversationKey != null) {
      if (!_conversationKeyLoaded && mounted) {
        setState(() => _conversationKeyLoaded = true);
      }
      return;
    }
    if (_keyLoading) return;
    _keyLoading = true;
    try {
      final pair = await ensureKeyPair();
      try {
        await publishPublicKeyIfNeeded(pair: pair);
      } catch (_) {
        // Publishing must never block the chat (e.g. pre-migration 012).
      }
      final loaded = await loadOrCreateConversationKey(
        widget.conversationId,
        _memberDeviceKeys,
        afterReset: afterReset,
      );
      final key = loaded.key;
      if (mounted) {
        setState(() {
          // Whether the last load definitively failed (a wrapped row
          // exists but unwraps with neither KEK). Transient outcomes
          // (no row yet / network) report blocked: false, so pending
          // rows stay in "decrypting" and keep their bounded retry.
          _keyDefinitivelyBlocked = loaded.blocked;
          if (key != null) {
            _conversationKey = key;
            _conversationKeyLoaded = true;
            // The key is here now: rows marked failed only because
            // there was no key get another chance.
            _decryptFailed.clear();
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
            await wrapKeyForMembers(
                widget.conversationId, key, _memberDeviceKeys);
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
      }
    } catch (_) {
      // Deliberately do NOT set _conversationKeyLoaded: a transient
      // failure must be retryable (bounded, see _maybeRetryKeyLoad).
    } finally {
      _keyLoading = false;
    }
  }

  /// Bounded key retry: at most once per ~10s, only when new stream
  /// data arrives while there is still no key.
  void _maybeRetryKeyLoad() {
    if (_conversationKey != null || _keyLoading) return;
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
  /// Malformed rows (missing ciphertext/nonce) are skipped, never marked
  /// failed. Rows that cannot be decrypted only because the key is null
  /// are NOT marked failed either — they are retried when the key loads
  /// — EXCEPT when the key load definitively failed (a wrapped row
  /// exists but unwraps with neither KEK): those rows are marked failed
  /// so the UI shows "تعذّر فك التشفير" with a tap-to-retry instead of
  /// an eternal "جارٍ فك التشفير…".
  Future<void> _decryptPendingRows(List<Map<String, dynamic>> rows) async {
    if (_decryptRunning) return;
    final malformed = <String>[];
    final pending = rows.where((row) {
      if (!isEncryptedMessage(row)) return false;
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) return false;
      if (isMalformedEncryptedRow(row)) {
        malformed.add(id);
        return false;
      }
      return !_decrypted.containsKey(id) &&
          !_decrypting.contains(id) &&
          !_decryptFailed.contains(id);
    }).toList();
    if (malformed.isNotEmpty && mounted) {
      setState(() => _malformedIds.addAll(malformed));
    }
    if (pending.isEmpty) return;
    if (!_conversationKeyLoaded) {
      // No key yet. If the load already failed definitively, fall
      // through and mark the pending rows failed below — waiting
      // would never heal them. Otherwise trigger a (bounded) load
      // and wait for it.
      if (!_keyDefinitivelyBlocked) {
        await _ensureConversationKey();
        if (!mounted) return;
        // Key load triggers a rebuild, which re-schedules this step.
        return;
      }
    }
    final key = _conversationKey;
    if (key == null) {
      // No key yet. A definitive load failure marks these rows failed
      // (retry affordance in the UI). A transient failure (no row yet
      // / network) leaves them pending: the builder re-schedules
      // decryption (bounded) when new data arrives or the key loads.
      if (_keyDefinitivelyBlocked && mounted) {
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
        _decryptFailed.add(id);
        changed = true;
      } finally {
        _decrypting.remove(id);
      }
    }
    _decryptRunning = false;
    if (changed && mounted) setState(() {});
  }

  /// Tap-to-retry for rows that definitively failed to decrypt: clears
  /// the failed set and the blocked flag, then re-runs the key load
  /// (which re-runs decryption when the key arrives). If the key is
  /// still blocked, the rows fail again — the retry is honest, never a
  /// silent spin back to "جارٍ فك التشفير…".
  void _retryDecryption() {
    if (!mounted) return;
    setState(() {
      _decryptFailed.clear();
      _keyDefinitivelyBlocked = false;
    });
    _ensureConversationKey();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    if (extent > 0) _scroll.jumpTo(extent);
  }

  @override
  void dispose() {
    currentOpenConversationId.value = null;
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
  bool get _showPlaintextBanner =>
      _membersLoaded &&
      (_conversationKey == null || !canEncryptFor(_memberDeviceKeys));

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

  Future<void> _resetEncryption() async {
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
    // are about the row format, not the key.
    setState(() {
      _conversationKey = null;
      _conversationKeyLoaded = false;
      _keyDefinitivelyBlocked = false;
      _decrypted.clear();
      _decryptFailed.clear();
    });
    _ensureConversationKey(afterReset: true);
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
  Widget _messageBody(Map<String, dynamic> row) {
    const labelStyle = TextStyle(fontSize: 10, color: Colors.black54);
    if (isEncryptedMessage(row)) {
      final id = row['id']?.toString() ?? '';
      final plain = _decrypted[id];
      if (plain != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plain),
            const Text('🔒 مشفّرة', style: labelStyle),
          ],
        );
      }
      if (_malformedIds.contains(id)) {
        return const Text('رسالة تالفة');
      }
      if (_decryptFailed.contains(id)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('تعذّر فك تشفير هذه الرسالة'),
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
      }
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(encryptedMessagePlaceholder),
          Text('جارٍ فك التشفير…', style: labelStyle),
        ],
      );
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
          await publishPublicKeyIfNeeded(pair: pair);
        } catch (_) {
          // Publishing must never block sending.
        }
        await _loadMembers(silent: true);
        final loadedKey = await loadOrCreateConversationKey(
            widget.conversationId, _memberDeviceKeys);
        convKey = loadedKey.key;
        if (convKey != null) {
          try {
            await wrapKeyForMembers(
                widget.conversationId, convKey, _memberDeviceKeys);
          } catch (_) {
            // Lazy re-wrap is best-effort; the message still goes out.
          }
          canEncrypt = canEncryptFor(_memberDeviceKeys);
          if (mounted) {
            setState(() {
              _conversationKey = convKey;
              _conversationKeyLoaded = true;
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
  Widget _buildMessageList(List<Map<String, dynamic>> rows,
      {bool showLiveHint = false}) {
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
    final list = ListView.builder(
      controller: _scroll,
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
    );
    if (!showLiveHint) return list;
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: const Color(0xFFFFF3CD),
        child: const Text('التحديثات الحية غير متصلة — تُعرض الرسائل المحفوظة.',
            style: TextStyle(fontSize: 12)),
      ),
      Expanded(child: list),
    ]);
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
                return _buildMessageList(_fallbackRows!,
                    showLiveHint: true);
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
