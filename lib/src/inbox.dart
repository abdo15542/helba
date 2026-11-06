import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_panel.dart';
import 'chat.dart';
import 'channels.dart';
import 'config.dart';
import 'push.dart';
import 'stories.dart';
import 'utils.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/chat_inbox_helpers_test.dart).
// ---------------------------------------------------------------------------

/// Normalises Arabic text for search: أ/إ/آ → ا، ة → ه، ي → ى، and
/// strips diacritics. Applied to both the query and the searchable text.
String normalizeArabicForSearch(String value) {
  var text = value;
  text = text.replaceAll(RegExp(r'[أإآ]'), 'ا');
  text = text.replaceAll('ة', 'ه');
  text = text.replaceAll('ي', 'ى');
  text = text.replaceAll(RegExp(r'[\u064B-\u0652\u0670]'), '');
  return text;
}

/// Friendly Arabic message for inbox failures. networkErrorMessage does
/// not cover TimeoutException (utils.dart is not ours to edit here), so
/// that case is mapped locally.
String inboxErrorMessage(Object e) {
  if (e is TimeoutException) {
    return 'انتهت المهلة. تحقق من اتصالك بالإنترنت وحاول مجدداً.';
  }
  return networkErrorMessage(e) ??
      'تعذر تحميل المحادثات. تحقق من الاتصال وحاول مجدداً.';
}

/// Display name for a user row: display_name, else @username, else
/// the generic fallback — never a blank tile.
String displayNameForUser(Map<String, dynamic> user) {
  final display = user['display_name']?.toString().trim();
  if (display != null && display.isNotEmpty) return display;
  final username = user['username']?.toString().trim();
  if (username != null && username.isNotEmpty) return '@$username';
  return 'مستخدم';
}

/// Latest message per conversation, from rows ordered newest-first
/// (first row per conversation wins).
Map<String, Map<String, dynamic>> latestMessageByConversation(
    List<Map<String, dynamic>> rows) {
  final latest = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final id = row['conversation_id']?.toString() ?? '';
    if (id.isEmpty) continue;
    latest.putIfAbsent(id, () => row);
  }
  return latest;
}

class InboxPage extends StatefulWidget {
  final bool isAdmin;
  const InboxPage({super.key, this.isAdmin = false});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final search = TextEditingController();
  String query = '';
  Timer? _searchDebounce;
  // The chats future must live in state: creating it inside build() refetched
  // from Supabase on every rebuild, including every keystroke in search.
  late Future<List<Map<String, dynamic>>> _chatsFuture;
  // Latest message per conversation id (loaded alongside the chats).
  Map<String, Map<String, dynamic>> _lastMessages = {};
  // Bumped on pull-to-refresh so the story rings reload too.
  final _storiesTick = ValueNotifier<int>(0);
  bool _refreshing = false;
  RealtimeChannel? _realtimeChannel;
  Timer? _realtimeDebounce;
  bool _pushDeniedPromptShown = false;

  @override
  void initState() {
    super.initState();
    _chatsFuture = loadChats();
    _subscribeInboxRealtime();
    pushNotificationsPermanentlyDenied.addListener(_onPushDeniedChanged);
  }

  /// One-time prompt when system notifications are permanently denied:
  /// without them, no alerts arrive while the app is closed. Offers a
  /// shortcut to the app's notification settings.
  void _onPushDeniedChanged() {
    if (!pushNotificationsPermanentlyDenied.value ||
        _pushDeniedPromptShown ||
        !mounted) {
      return;
    }
    _pushDeniedPromptShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'الإشعارات معطّلة من إعدادات النظام — لن تصلك التنبيهات عند إغلاق التطبيق.'),
        action: SnackBarAction(
          label: 'الإعدادات',
          onPressed: () => unawaited(openAppNotificationSettings()),
        ),
      ),
    );
  }

  /// Live inbox updates: a new message, or a conversation's updated_at
  /// changing, schedules a debounced refresh (~500ms). One channel for
  /// both tables; unsubscribed in dispose().
  void _subscribeInboxRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final channel = Supabase.instance.client.channel('inbox:$uid');
    channel.onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'messages',
        callback: (_) => _scheduleRealtimeRefresh());
    channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'conversations',
        callback: (_) => _scheduleRealtimeRefresh());
    channel.subscribe();
    _realtimeChannel = channel;
  }

  void _scheduleRealtimeRefresh() {
    _realtimeDebounce?.cancel();
    _realtimeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _refresh();
    });
  }

  /// Refreshes the inbox but keeps the old (good) data when the refresh
  /// fails, and never runs two refreshes concurrently.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final future = loadChats();
      await future;
      if (mounted) {
        setState(() => _chatsFuture = future);
        _storiesTick.value++;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(inboxErrorMessage(e))),
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    pushNotificationsPermanentlyDenied.removeListener(_onPushDeniedChanged);
    _searchDebounce?.cancel();
    _realtimeDebounce?.cancel();
    final channel = _realtimeChannel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    search.dispose();
    _storiesTick.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> loadChats() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await Supabase.instance.client
        .from('conversation_members')
        .select(
            'conversation_id, conversations(id,kind,title,is_public,updated_at,conversation_members(user_id,role,profiles(display_name,username)))')
        .eq('user_id', uid)
        .order('updated_at', ascending: false, referencedTable: 'conversations')
        .limit(100)
        .timeout(const Duration(seconds: 15));
    // Drop rows whose embedded conversation is null (orphaned
    // membership): the builder must never receive one (C1).
    final chats = rows
        .cast<Map<String, dynamic>>()
        .where((r) => r['conversations'] is Map<String, dynamic>)
        .toList();
    // Sort by parsed DateTime, not by string comparison (M18).
    DateTime updatedAtOf(Map<String, dynamic> r) {
      final raw =
          (r['conversations'] as Map<String, dynamic>?)?['updated_at']
              ?.toString();
      return DateTime.tryParse(raw ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }

    chats.sort((a, b) => updatedAtOf(b).compareTo(updatedAtOf(a)));
    // Latest message per conversation, in one query: messages for the
    // loaded ids, newest first, then pick the first per conversation
    // client-side. Best-effort: a failure here must not fail the inbox.
    try {
      final ids = chats
          .map((r) =>
              (r['conversations'] as Map<String, dynamic>)['id']?.toString() ??
              '')
          .where((id) => id.isNotEmpty)
          .toList();
      if (ids.isNotEmpty) {
        final messages = await Supabase.instance.client
            .from('messages')
            .select('id,conversation_id,sender_id,body,is_encrypted,message_type,created_at')
            .inFilter('conversation_id', ids)
            .order('created_at', ascending: false)
            .limit(100)
            .timeout(const Duration(seconds: 15));
        _lastMessages = latestMessageByConversation(
            messages.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // Keep whatever last messages we already had (possibly none).
    }
    return chats;
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تسجيل الخروج؟'),
        content: const Text('هل تريد تسجيل الخروج من هلبة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('تسجيل الخروج')),
        ],
      ),
    );
    if (confirmed != true) return;
    // Await/error/busy handling of the sign-out itself lives in auth.dart;
    // this dialog is the inbox-side confirmation (M25).
    await Supabase.instance.client.auth.signOut();
  }

  String _searchableText(Map<String, dynamic>? c, String? currentUserId) {
    final members = (c?['conversation_members'] as List<dynamic>? ?? []);
    final parts = <String>[c?['title']?.toString() ?? ''];
    for (final m in members) {
      if (m is! Map) continue;
      if (m['user_id']?.toString() == currentUserId) continue;
      final profile = m['profiles'] as Map<String, dynamic>?;
      parts.add(profile?['display_name']?.toString() ?? '');
      parts.add(profile?['username']?.toString() ?? '');
    }
    return normalizeArabicForSearch(parts.join(' ').toLowerCase());
  }

  Widget _chatSubtitle(
      Map<String, dynamic> c, String kind, String? currentUserId) {
    final last = _lastMessages[c['id']?.toString()];
    if (last == null) return Text(channelSubtitle(kind));
    final isEncrypted = last['is_encrypted'] == true;
    final body = isEncrypted
        ? '🔒 رسالة مشفّرة'
        : (last['body']?.toString() ?? '');
    final fromOther = last['sender_id']?.toString() != currentUserId;
    final time = DateTime.tryParse(last['created_at']?.toString() ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontWeight: fromOther ? FontWeight.bold : FontWeight.normal)),
        if (time != null)
          Text(formatChatTime(time),
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('هلبة',
              style: TextStyle(
                  fontSize: 27, fontWeight: FontWeight.w900, color: green)),
          actions: [
            if (widget.isAdmin)
              IconButton(
                  tooltip: 'لوحة الإدارة',
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminPanelPage())),
                  icon: const Icon(Icons.admin_panel_settings_outlined)),
            IconButton(
                tooltip: 'القنوات العامة',
                onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const ChannelDirectorySheet()),
                icon: const Icon(Icons.campaign_outlined)),
            IconButton(
                tooltip: 'تسجيل الخروج',
                onPressed: _confirmSignOut,
                icon: const Icon(Icons.logout))
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: green,
          foregroundColor: Colors.white,
          onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const NewChatSheet()),
          icon: const Icon(Icons.add_comment_outlined),
          label: const Text('محادثة جديدة'),
        ),
        body: Column(children: [
          StoryRingsRow(refreshTick: _storiesTick),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: search,
              onChanged: (v) {
                // Debounce the setState so per-keystroke typing does not
                // rebuild the whole screen (M26).
                _searchDebounce?.cancel();
                _searchDebounce =
                    Timer(const Duration(milliseconds: 150), () {
                  if (mounted) setState(() => query = v);
                });
              },
              decoration: InputDecoration(
                  hintText: 'ابحث في محادثاتك',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none)),
            ),
          ),
          Expanded(
              child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: _chatsFuture,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) {
                        // Scrollable so pull-to-refresh still fires, with
                        // a retry button and a mapped Arabic error (B6).
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(inboxErrorMessage(snap.error!),
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                        onPressed: _refresh,
                                        child:
                                            const Text('إعادة المحاولة')),
                                  ]),
                            ),
                          ],
                        );
                      }
                      final currentUserId =
                          Supabase.instance.client.auth.currentUser?.id;
                      final normalizedQuery = normalizeArabicForSearch(
                          query.trim().toLowerCase());
                      final chats = (snap.data ?? []).where((r) {
                        final c = r['conversations'] as Map<String, dynamic>?;
                        if (c == null) return false;
                        return _searchableText(c, currentUserId)
                            .contains(normalizedQuery);
                      }).toList();
                      if (chats.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            query.trim().isEmpty
                                ? const _EmptyInbox()
                                : const Padding(
                                    padding: EdgeInsets.all(32),
                                    child: Text(
                                        'لا توجد نتائج مطابقة لبحثك.',
                                        textAlign: TextAlign.center)),
                          ],
                        );
                      }
                      return ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: chats.length,
                        separatorBuilder: (_, __) =>
                            const Divider(indent: 84, height: 1),
                        itemBuilder: (context, i) {
                          // Nullable cast with a fallback tile (C1):
                          // a null conversation never crashes the inbox.
                          final c = chats[i]['conversations']
                              as Map<String, dynamic>?;
                          if (c == null) {
                            return const ListTile(
                                title: Text('محادثة غير متوفرة'));
                          }
                          final members =
                              (c['conversation_members'] as List<dynamic>? ??
                                  []);
                          final others = members
                              .where((m) =>
                                  m is Map &&
                                  m['user_id']?.toString() != currentUserId)
                              .toList();
                          final other = others.isEmpty
                              ? null
                              : Map<String, dynamic>.from(others.first as Map);
                          final profile =
                              other?['profiles'] as Map<String, dynamic>?;
                          final displayTitle =
                              c['title']?.toString().trim().isNotEmpty == true
                                  ? c['title'].toString()
                                  : (profile?['display_name']
                                              ?.toString()
                                              .trim()
                                              .isNotEmpty ==
                                          true
                                      ? profile!['display_name'].toString()
                                      : (profile?['username']
                                                  ?.toString()
                                                  .isNotEmpty ==
                                              true
                                          ? '@${profile!['username']}'
                                          : 'محادثة'));
                          final kind = c['kind']?.toString() ?? 'direct';
                          final isAdmin =
                              roleInConversation(c, currentUserId) == 'admin';
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFFE1F1E8),
                              child: Icon(
                                  kind == 'channel'
                                      ? Icons.campaign_rounded
                                      : kind == 'group'
                                          ? Icons.groups_rounded
                                          : Icons.person,
                                  color: green),
                            ),
                            title: Row(children: [
                              Expanded(
                                  child: Text(displayTitle,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold))),
                              if (kind == 'channel')
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                      color: const Color(0xFFE1F1E8),
                                      borderRadius: BorderRadius.circular(10)),
                                  child: const Text('قناة',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: green)),
                                ),
                            ]),
                            subtitle:
                                _chatSubtitle(c, kind, currentUserId),
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => ChatPage(
                                        conversationId: c['id'].toString(),
                                        title: displayTitle,
                                        kind: kind,
                                        isAdmin: isAdmin))).then(
                                (_) => _refresh()),
                          );
                        },
                      );
                    },
                  ))),
        ]),
      );
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();
  @override
  Widget build(BuildContext context) => const Center(
          child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline, size: 58, color: green),
          SizedBox(height: 12),
          Text('لا توجد محادثات بعد',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          Text('ابدأ محادثة جديدة مع أحد مستخدمي هلبة.'),
        ]),
      ));
}

class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});
  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  final controller = TextEditingController();
  List<Map<String, dynamic>> users = [];
  final Set<String> selectedIds = {};
  final groupTitle = TextEditingController();
  bool busy = false;
  // 'direct' | 'group' | 'channel'
  String mode = 'direct';
  bool get creatingGroup => mode == 'group';
  bool get creatingChannel => mode == 'channel';
  bool get creatingGroupOrChannel => creatingGroup || creatingChannel;
  String? error;
  bool _searchHint = false;

  int _searchRequest = 0;
  Timer? _findUsersTimer;

  /// Debounced user search (300ms): the actual query runs in
  /// _doFindUsers, not on every keystroke (M14).
  void findUsers(String value) {
    _findUsersTimer?.cancel();
    _findUsersTimer = Timer(const Duration(milliseconds: 300), () {
      _doFindUsers(value);
    });
  }

  Future<void> _doFindUsers(String value) async {
    final term = value.trim().replaceAll(RegExp(r'[,(){}]'), ' ');
    final request = ++_searchRequest;
    if (term.length < 2) {
      if (mounted) {
        setState(() {
          users = [];
          busy = false;
          error = null;
          // Hint for short terms instead of silently clearing (M14).
          _searchHint = term.isNotEmpty;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
        _searchHint = false;
      });
    }
    try {
      final me = Supabase.instance.client.auth.currentUser?.id;
      if (me == null) {
        if (mounted && request == _searchRequest) {
          setState(() => error = 'انتهت الجلسة. سجّل الدخول مجدداً.');
        }
        return;
      }
      final safeTerm = term.replaceAll('%', '').replaceAll('_', '');
      // A term of only %/_ would become an empty pattern matching ALL
      // users: skip the query instead (M14).
      if (safeTerm.trim().isEmpty) {
        if (mounted && request == _searchRequest) {
          setState(() {
            users = [];
            error = null;
          });
        }
        return;
      }
      final result = await Supabase.instance.client
          .from('profiles')
          .select('id,display_name,username')
          .neq('id', me)
          .or('username.ilike.%$safeTerm%,display_name.ilike.%$safeTerm%')
          .limit(20)
          .timeout(const Duration(seconds: 15));
      if (!mounted || request != _searchRequest) return;
      setState(() {
        users = result.cast<Map<String, dynamic>>();
        error = null;
      });
    } on TimeoutException {
      if (mounted && request == _searchRequest) {
        setState(() => error = 'انتهت المهلة. تحقق من الاتصال وحاول مجدداً.');
      }
    } catch (_) {
      if (mounted && request == _searchRequest) {
        setState(() => error = 'تعذر البحث عن المستخدمين.');
      }
    } finally {
      if (mounted && request == _searchRequest) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> createGroup() async {
    if (groupTitle.text.trim().length < 2 || selectedIds.isEmpty) {
      setState(() => error = 'اكتب اسم المجموعة واختر عضواً واحداً على الأقل.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await Supabase.instance.client
          .rpc(
            'create_group_conversation',
            params: {
              'group_title': groupTitle.text.trim(),
              'member_ids': selectedIds.toList()
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      // Validate the RPC result as a UUID before navigating: a null
      // result .toString()s to the literal string "null" (M16).
      final conversationId = asUuidOrNull(result);
      if (conversationId == null) {
        setState(() =>
            error = 'تعذر إنشاء المجموعة. تحقق من إعداد قاعدة البيانات.');
        return;
      }
      final title = groupTitle.text.trim();
      // Capture the navigator before popping: the sheet's context is
      // deactivated by the pop (C2).
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(
          builder: (_) => ChatPage(
              conversationId: conversationId,
              title: title,
              kind: 'group',
              isAdmin: true)));
    } on TimeoutException {
      if (mounted) {
        setState(() =>
            error = 'انتهت المهلة. تحقق من الاتصال وحاول مجدداً.');
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            error = 'تعذر إنشاء المجموعة. تأكد من تطبيق ترحيل قاعدة البيانات رقم 002.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> createChannel() async {
    // A solo channel is allowed: members are optional here (M16).
    if (groupTitle.text.trim().length < 2) {
      setState(() => error = 'اكتب اسم القناة.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await Supabase.instance.client
          .rpc(
            'create_channel',
            params: {
              'channel_title': groupTitle.text.trim(),
              'member_ids': selectedIds.toList()
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      final conversationId = asUuidOrNull(result);
      if (conversationId == null) {
        setState(() =>
            error = 'تعذر إنشاء القناة. تحقق من إعداد قاعدة البيانات.');
        return;
      }
      final title = groupTitle.text.trim();
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(
          builder: (_) => ChatPage(
              conversationId: conversationId,
              title: title,
              kind: 'channel',
              isAdmin: true)));
    } on TimeoutException {
      if (mounted) {
        setState(() =>
            error = 'انتهت المهلة. تحقق من الاتصال وحاول مجدداً.');
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            error = 'تعذر إنشاء القناة. تأكد من تطبيق ترحيل قاعدة البيانات رقم 008.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startChat(Map<String, dynamic> user) async {
    setState(() => busy = true);
    try {
      final result = await Supabase.instance.client
          .rpc('create_direct_conversation',
              params: {'target_user': user['id']})
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      final conversationId = asUuidOrNull(result);
      if (conversationId == null) {
        setState(() =>
            error = 'تعذر إنشاء المحادثة. تحقق من إعداد قاعدة البيانات.');
        return;
      }
      // Trim-or-fallback title: an empty-string display name must not
      // yield an empty title (M16).
      final display = user['display_name']?.toString().trim();
      final username = user['username']?.toString().trim();
      final title = (display != null && display.isNotEmpty)
          ? display
          : (username != null && username.isNotEmpty)
              ? '@$username'
              : 'محادثة';
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(
          builder: (_) =>
              ChatPage(conversationId: conversationId, title: title)));
    } on TimeoutException {
      if (mounted) {
        setState(() =>
            error = 'انتهت المهلة. تحقق من الاتصال وحاول مجدداً.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'تعذر إنشاء المحادثة. تحقق من إعداد قاعدة البيانات.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    _findUsersTimer?.cancel();
    controller.dispose();
    groupTitle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
                child: Text(
                    creatingChannel
                        ? 'إنشاء قناة'
                        : creatingGroup
                            ? 'إنشاء مجموعة'
                            : 'محادثة جديدة',
                    style: const TextStyle(
                        fontSize: 21, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'direct',
                  icon: Icon(Icons.person_outline),
                  label: Text('محادثة فردية')),
              ButtonSegment(
                  value: 'group',
                  icon: Icon(Icons.groups_outlined),
                  label: Text('مجموعة')),
              ButtonSegment(
                  value: 'channel',
                  icon: Icon(Icons.campaign_outlined),
                  label: Text('قناة')),
            ],
            selected: {mode},
            onSelectionChanged: (selected) => setState(() {
              mode = selected.first;
              selectedIds.clear();
              error = null;
              // Mode switch clears stale search results AND text (M30).
              users = [];
              controller.clear();
              _searchHint = false;
              _findUsersTimer?.cancel();
            }),
          ),
          if (creatingGroupOrChannel) ...[
            const SizedBox(height: 10),
            TextField(
                controller: groupTitle,
                decoration: InputDecoration(
                    labelText:
                        creatingChannel ? 'اسم القناة' : 'اسم المجموعة',
                    border: const OutlineInputBorder())),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          TextField(
              controller: controller,
              onChanged: findUsers,
              decoration: const InputDecoration(
                  hintText: 'ابحث بالاسم أو اسم المستخدم',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder())),
          if (_searchHint)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('اكتب حرفين على الأقل للبحث.',
                    style: TextStyle(color: Colors.black54))),
          if (busy)
            const Padding(
                padding: EdgeInsets.all(10), child: LinearProgressIndicator()),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          Flexible(
              child: ListView(
                  shrinkWrap: true,
                  children: users
                      .map((u) {
                        final username = u['username']?.toString().trim() ?? '';
                        return ListTile(
                            leading:
                                const CircleAvatar(child: Icon(Icons.person)),
                            title: Text(displayNameForUser(u)),
                            subtitle: username.isNotEmpty
                                ? Text('@$username')
                                : null,
                            trailing: creatingGroupOrChannel
                                ? Checkbox(
                                    value: selectedIds
                                        .contains(u['id'].toString()),
                                    onChanged: (checked) => setState(() {
                                      final id = u['id'].toString();
                                      if (checked == true) {
                                        selectedIds.add(id);
                                      } else {
                                        selectedIds.remove(id);
                                      }
                                    }),
                                  )
                                : null,
                            onTap: () {
                              if (creatingGroupOrChannel) {
                                setState(() {
                                  final id = u['id'].toString();
                                  if (!selectedIds.add(id)) {
                                    selectedIds.remove(id);
                                  }
                                });
                              } else {
                                startChat(u);
                              }
                            },
                          );
                      })
                      .toList())),
          if (creatingGroupOrChannel)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy
                        ? null
                        : creatingChannel
                            ? createChannel
                            : createGroup,
                    icon: Icon(creatingChannel
                        ? Icons.campaign_outlined
                        : Icons.group_add_outlined),
                    label: Text(creatingChannel
                        ? 'إنشاء القناة (${selectedIds.length})'
                        : 'إنشاء المجموعة (${selectedIds.length})'),
                  )),
            ),
        ]),
      );
}
