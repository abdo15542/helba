import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_panel.dart';
import 'chat.dart';
import 'channels.dart';
import 'config.dart';
import 'stories.dart';

class InboxPage extends StatefulWidget {
  final bool isAdmin;
  const InboxPage({super.key, this.isAdmin = false});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final search = TextEditingController();
  String query = '';
  // The chats future must live in state: creating it inside build() refetched
  // from Supabase on every rebuild, including every keystroke in search.
  late Future<List<Map<String, dynamic>>> _chatsFuture;
  // Bumped on pull-to-refresh so the story rings reload too.
  final _storiesTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _chatsFuture = loadChats();
  }

  Future<void> _refresh() async {
    final future = loadChats();
    _storiesTick.value++;
    if (mounted) setState(() => _chatsFuture = future);
    // Swallow here: the FutureBuilder above already surfaces the error.
    try {
      await future;
    } catch (_) {}
  }

  @override
  void dispose() {
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
        .eq('user_id', uid);
    final chats = rows.cast<Map<String, dynamic>>();
    // Newest conversation first; the query itself returns no ordering.
    chats.sort((a, b) {
      final aUpdated =
          (a['conversations'] as Map<String, dynamic>?)?['updated_at']
                  ?.toString() ??
              '';
      final bUpdated =
          (b['conversations'] as Map<String, dynamic>?)?['updated_at']
                  ?.toString() ??
              '';
      return bUpdated.compareTo(aUpdated);
    });
    return chats;
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
                onPressed: () => Supabase.instance.client.auth.signOut(),
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
              onChanged: (v) => setState(() => query = v),
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
                        return Center(
                            child:
                                Text('تعذر تحميل المحادثات: ${snap.error}'));
                      }
                      final currentUserId =
                          Supabase.instance.client.auth.currentUser?.id;
                      final chats = (snap.data ?? []).where((r) {
                        final c = r['conversations'] as Map<String, dynamic>?;
                        final members =
                            (c?['conversation_members'] as List<dynamic>? ??
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
                        final searchable = [
                          c?['title']?.toString() ?? '',
                          profile?['display_name']?.toString() ?? '',
                          profile?['username']?.toString() ?? '',
                        ].join(' ').toLowerCase();
                        return searchable
                            .contains(query.trim().toLowerCase());
                      }).toList();
                      if (chats.isEmpty) {
                        return query.trim().isEmpty
                            ? const _EmptyInbox()
                            : const Center(
                                child: Text('لا توجد نتائج مطابقة لبحثك.'));
                      }
                      return ListView.separated(
                        itemCount: chats.length,
                        separatorBuilder: (_, __) =>
                            const Divider(indent: 84, height: 1),
                        itemBuilder: (context, i) {
                          final c =
                              chats[i]['conversations'] as Map<String, dynamic>;
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
                            subtitle: Text(channelSubtitle(kind)),
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

  int _searchRequest = 0;

  Future<void> findUsers(String value) async {
    final term = value.trim().replaceAll(RegExp(r'[,(){}]'), ' ');
    final request = ++_searchRequest;
    if (term.length < 2) {
      if (mounted) {
        setState(() {
          users = [];
          busy = false;
          error = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      final me = Supabase.instance.client.auth.currentUser!.id;
      final safeTerm = term.replaceAll('%', '').replaceAll('_', '');
      final result = await Supabase.instance.client
          .from('profiles')
          .select('id,display_name,username')
          .neq('id', me)
          .or('username.ilike.%$safeTerm%,display_name.ilike.%$safeTerm%')
          .limit(20);
      if (!mounted || request != _searchRequest) return;
      setState(() {
        users = result.cast<Map<String, dynamic>>();
        error = null;
      });
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
      final result = await Supabase.instance.client.rpc(
        'create_group_conversation',
        params: {
          'group_title': groupTitle.text.trim(),
          'member_ids': selectedIds.toList()
        },
      );
      if (!mounted) return;
      final title = groupTitle.text.trim();
      Navigator.pop(context);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversationId: result.toString(),
                  title: title,
                  kind: 'group')));
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
    if (groupTitle.text.trim().length < 2 || selectedIds.isEmpty) {
      setState(() => error = 'اكتب اسم القناة واختر عضواً واحداً على الأقل.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await Supabase.instance.client.rpc(
        'create_channel',
        params: {
          'channel_title': groupTitle.text.trim(),
          'member_ids': selectedIds.toList()
        },
      );
      if (!mounted) return;
      final title = groupTitle.text.trim();
      Navigator.pop(context);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversationId: result.toString(),
                  title: title,
                  kind: 'channel')));
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
      final result = await Supabase.instance.client.rpc(
          'create_direct_conversation',
          params: {'target_user': user['id']});
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversationId: result.toString(),
                  title: user['display_name']?.toString() ?? 'محادثة')));
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
          if (busy)
            const Padding(
                padding: EdgeInsets.all(10), child: LinearProgressIndicator()),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          Flexible(
              child: ListView(
                  shrinkWrap: true,
                  children: users
                      .map((u) => ListTile(
                            leading:
                                const CircleAvatar(child: Icon(Icons.person)),
                            title: Text(u['display_name']?.toString() ?? ''),
                            subtitle: Text('@${u['username'] ?? ''}'),
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
                          ))
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
