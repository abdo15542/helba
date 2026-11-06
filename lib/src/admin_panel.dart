import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin.dart';
import 'chat.dart';
import 'config.dart';

class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});
  @override
  State<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends State<AdminPanelPage> {
  // Admin gate: the panel must never trust the button that opened it.
  // The profile is loaded first; missing row / non-admin / signed out
  // all fail CLOSED (canSeeAdminPanel(null) is false).
  late Future<Map<String, dynamic>?> _gateFuture;
  bool _loadsStarted = false;
  late Future<Map<String, dynamic>> _statsFuture;
  late Future<List<Map<String, dynamic>>> _usersFuture;
  late Future<List<Map<String, dynamic>>> _reportsFuture;
  late Future<Map<String, Map<String, dynamic>>> _targetsFuture;
  bool _busy = false;
  int _usersLimit = 100;
  int _reportsLimit = 100;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _gateFuture = loadMyProfile();
  }

  void _loadAll() {
    _statsFuture = loadAdminStats();
    _usersFuture = loadAllUsers(limit: _usersLimit, query: _searchQuery);
    _reportsFuture = loadReports(limit: _reportsLimit);
    // Resolve reported content for the loaded page (batch fetch).
    _targetsFuture = _reportsFuture.then(
      (reports) => resolveReportTargets(reports),
      onError: (_) => <String, Map<String, dynamic>>{},
    );
  }

  /// Starts the tab loads once, after the admin gate has passed.
  void _ensureLoadsStarted() {
    if (_loadsStarted) return;
    _loadsStarted = true;
    _loadAll();
  }

  Future<void> _refresh() async {
    final stats = loadAdminStats();
    final users = loadAllUsers(limit: _usersLimit, query: _searchQuery);
    final reports = loadReports(limit: _reportsLimit);
    final targets = reports.then(
      (rows) => resolveReportTargets(rows),
      onError: (_) => <String, Map<String, dynamic>>{},
    );
    if (mounted) {
      setState(() {
        _statsFuture = stats;
        _usersFuture = users;
        _reportsFuture = reports;
        _targetsFuture = targets;
      });
    }
    try {
      await Future.wait([stats, users, reports]);
    } catch (_) {
      // Each tab's FutureBuilder already surfaces its own error.
    }
  }

  void _onSearch(String query) {
    if (query.trim() == _searchQuery.trim()) return;
    setState(() {
      _searchQuery = query.trim();
      _usersLimit = 100;
    });
    _refresh();
  }

  void _showMoreUsers() {
    setState(() => _usersLimit += 100);
    _refresh();
  }

  void _showMoreReports() {
    setState(() => _reportsLimit += 100);
    _refresh();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setBanned(Map<String, dynamic> user, bool banned) async {
    final name = user['display_name']?.toString().trim().isNotEmpty == true
        ? user['display_name'].toString()
        : '@${user['username'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(banned ? 'حظر المستخدم؟' : 'إلغاء حظر المستخدم؟'),
        content: Text(banned
            ? 'سيتم منع $name من استخدام التطبيق.'
            : 'سيتم السماح لـ $name باستخدام التطبيق مجدداً.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await setUserBanned(user['id'].toString(), banned);
      await _refresh();
    } catch (_) {
      _showError('تعذر تحديث حالة المستخدم. تحقق من الاتصال وحاول مجدداً.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mute for 24h, or unmute when already muted. The set_user_muted RPC
  /// + muted_until column are backend-owned and may not be deployed yet:
  /// a failure is shown in a snackbar, never swallowed.
  Future<void> _setMuted(Map<String, dynamic> user, bool muted) async {
    final name = user['display_name']?.toString().trim().isNotEmpty == true
        ? user['display_name'].toString()
        : '@${user['username'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(muted ? 'كتم المستخدم؟' : 'إلغاء كتم المستخدم؟'),
        content: Text(muted
            ? 'سيتم كتم $name لمدة 24 ساعة (لا يمكنه إرسال الرسائل).'
            : 'سيتم السماح لـ $name بإرسال الرسائل مجدداً.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await setUserMuted(
        user['id'].toString(),
        muted ? DateTime.now().add(const Duration(hours: 24)) : null,
      );
      await _refresh();
    } catch (e) {
      _showError(
          'تعذر تحديث الكتم. تحقق من الاتصال — قد لا تكون ميزة الكتم مفعّلة بعد من الخادم. ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setReportStatus(
      Map<String, dynamic> report, bool reviewed) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(reviewed ? 'مراجعة البلاغ؟' : 'تجاهل البلاغ؟'),
        content: Text(reviewed
            ? 'سيتم وضع علامة "تمت المراجعة" على هذا البلاغ.'
            : 'سيتم وضع علامة "تم التجاهل" على هذا البلاغ.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      if (reviewed) {
        await reviewReport(report['id'].toString());
      } else {
        await dismissReport(report['id'].toString());
      }
      await _refresh();
    } catch (_) {
      _showError('تعذر تحديث البلاغ. تحقق من الاتصال وحاول مجدداً.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reopen a reviewed/dismissed report back to pending (undo).
  Future<void> _reopenReport(Map<String, dynamic> report) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إعادة فتح البلاغ؟'),
        content: const Text('سيعود البلاغ إلى حالة "قيد المراجعة".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await reopenReport(report['id'].toString());
      await _refresh();
    } catch (_) {
      _showError('تعذر إعادة فتح البلاغ. تحقق من الاتصال وحاول مجدداً.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openConversation(String conversationId, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          conversationId: conversationId,
          title: title,
          kind: 'direct',
        ),
      ),
    );
  }

  String _dateLabel(String? raw) {
    final parsed = DateTime.tryParse(raw ?? '');
    if (parsed == null) return '';
    return DateFormat('yyyy-MM-dd').format(parsed.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _gateFuture,
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: const Text('لوحة الإدارة')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        // Fail closed: any gate error, missing profile or non-admin
        // shows "not authorized" — the user lists are never loaded.
        if (gate.hasError || !canSeeAdminPanel(gate.data)) {
          return Scaffold(
            appBar: AppBar(title: const Text('لوحة الإدارة')),
            body: const Center(
              child: Text('غير مصرح. هذه الصفحة للمشرفين فقط.'),
            ),
          );
        }
        _ensureLoadsStarted();
        return _buildPanel(context);
      },
    );
  }

  Widget _buildPanel(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة الإدارة'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.bar_chart_outlined), text: 'الإحصائيات'),
            Tab(icon: Icon(Icons.people_outlined), text: 'المستخدمون'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'البلاغات'),
          ]),
          actions: [
            IconButton(
                tooltip: 'تحديث',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh)),
          ],
        ),
        body: TabBarView(children: [
          _StatsTab(future: _statsFuture),
          _UsersTab(
            future: _usersFuture,
            myId: myId,
            busy: _busy,
            dateLabel: _dateLabel,
            usersLimit: _usersLimit,
            onSearch: _onSearch,
            onShowMore: _showMoreUsers,
            onSetBanned: _setBanned,
            onSetMuted: _setMuted,
          ),
          _ReportsTab(
            future: _reportsFuture,
            targetsFuture: _targetsFuture,
            busy: _busy,
            dateLabel: _dateLabel,
            reportsLimit: _reportsLimit,
            onShowMore: _showMoreReports,
            onSetStatus: _setReportStatus,
            onReopen: _reopenReport,
            onOpenConversation: _openConversation,
          ),
        ]),
      ),
    );
  }
}

class _StatsTab extends StatelessWidget {
  final Future<Map<String, dynamic>> future;
  const _StatsTab({required this.future});

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return const Center(child: Text('تعذر تحميل الإحصائيات.'));
          }
          final stats = snap.data!;
          final cards = [
            ('المستخدمون', stats['users']),
            ('المحادثات', stats['conversations']),
            ('الرسائل', stats['messages']),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: cards
                .map((card) => Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text(card.$1,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                        trailing: Text('${card.$2 ?? 0}',
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: green)),
                      ),
                    ))
                .toList(),
          );
        },
      );
}

class _UsersTab extends StatefulWidget {
  final Future<List<Map<String, dynamic>>> future;
  final String? myId;
  final bool busy;
  final String Function(String?) dateLabel;
  final int usersLimit;
  final void Function(String) onSearch;
  final VoidCallback onShowMore;
  final Future<void> Function(Map<String, dynamic>, bool) onSetBanned;
  final Future<void> Function(Map<String, dynamic>, bool) onSetMuted;
  const _UsersTab({
    required this.future,
    required this.myId,
    required this.busy,
    required this.dateLabel,
    required this.usersLimit,
    required this.onSearch,
    required this.onShowMore,
    required this.onSetBanned,
    required this.onSetMuted,
  });

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'ابحث بالاسم أو اسم المستخدم…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'مسح البحث',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          widget.onSearch('');
                          setState(() {});
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: widget.onSearch,
              onChanged: (value) => setState(() {}),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: widget.future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return const Center(
                      child: Text('تعذر تحميل المستخدمين.'));
                }
                final users = snap.data ?? [];
                if (users.isEmpty) {
                  return const Center(child: Text('لا يوجد مستخدمون.'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: users.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    // Trailing "show more" row: the query is capped, so a
                    // full page means there may be more users.
                    if (i == users.length) {
                      if (users.length < widget.usersLimit) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: OutlinedButton(
                            onPressed:
                                widget.busy ? null : widget.onShowMore,
                            child: const Text('عرض المزيد'),
                          ),
                        ),
                      );
                    }
                    final user = users[i];
                    final isSelf = user['id']?.toString() == widget.myId;
                    final targetIsAdmin = isAdminProfile(user);
                    final banned = isBannedProfile(user);
                    // Defensive read: muted_until is absent until the
                    // backend adds the column (and the select lists it).
                    final muted = isMutedProfile(user);
                    final displayName = user['display_name']
                                ?.toString()
                                .trim()
                                .isNotEmpty ==
                            true
                        ? user['display_name'].toString()
                        : 'مستخدم';
                    final username = user['username']?.toString() ?? '';
                    return ListTile(
                      leading:
                          const CircleAvatar(child: Icon(Icons.person)),
                      title: Row(children: [
                        Expanded(
                            child: Text(displayName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                        if (targetIsAdmin)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Chip(
                                label: Text('مشرف',
                                    style: TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact),
                          ),
                        if (banned)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Chip(
                                label: Text('محظور',
                                    style: TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact),
                          ),
                        if (muted)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Chip(
                                label: Text('مكتوم',
                                    style: TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact),
                          ),
                      ]),
                      subtitle: Text(
                          '@$username${widget.dateLabel(user['created_at']?.toString()).isEmpty ? '' : ' • ${widget.dateLabel(user['created_at']?.toString())}'}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: (widget.busy || isSelf)
                                ? null
                                : () =>
                                    widget.onSetMuted(user, !muted),
                            child: Text(muted ? 'إلغاء الكتم' : 'كتم'),
                          ),
                          TextButton(
                            // An admin can never ban another admin
                            // (nor themselves); the SQL side rejects
                            // it too.
                            onPressed: (widget.busy ||
                                    isSelf ||
                                    targetIsAdmin)
                                ? null
                                : () =>
                                    widget.onSetBanned(user, !banned),
                            child: Text(banned ? 'إلغاء الحظر' : 'حظر'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      );
}

class _ReportsTab extends StatelessWidget {
  final Future<List<Map<String, dynamic>>> future;
  final Future<Map<String, Map<String, dynamic>>> targetsFuture;
  final bool busy;
  final String Function(String?) dateLabel;
  final int reportsLimit;
  final VoidCallback onShowMore;
  final Future<void> Function(Map<String, dynamic>, bool) onSetStatus;
  final Future<void> Function(Map<String, dynamic>) onReopen;
  final void Function(String, String) onOpenConversation;
  const _ReportsTab({
    required this.future,
    required this.targetsFuture,
    required this.busy,
    required this.dateLabel,
    required this.reportsLimit,
    required this.onShowMore,
    required this.onSetStatus,
    required this.onReopen,
    required this.onOpenConversation,
  });

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return const Center(child: Text('تعذر تحميل البلاغات.'));
          }
          final reports = snap.data ?? [];
          if (reports.isEmpty) {
            return const Center(child: Text('لا توجد بلاغات.'));
          }
          return FutureBuilder<Map<String, Map<String, dynamic>>>(
            future: targetsFuture,
            builder: (context, targetsSnap) {
              // Targets resolve in the background; the list is usable
              // while they load (unresolved targets show a placeholder).
              final targets = targetsSnap.data ?? {};
              return ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: reports.length + 1,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (i == reports.length) {
                    if (reports.length < reportsLimit) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: OutlinedButton(
                          onPressed: busy ? null : onShowMore,
                          child: const Text('عرض المزيد'),
                        ),
                      ),
                    );
                  }
                  final report = reports[i];
                  final reporter =
                      report['profiles'] as Map<String, dynamic>?;
                  final reporterName =
                      reporter?['display_name']?.toString().trim().isNotEmpty ==
                              true
                          ? reporter!['display_name'].toString()
                          : (reporter?['username']?.toString().isNotEmpty == true
                              ? '@${reporter!['username']}'
                              : 'مستخدم');
                  final targetId = report['target_id']?.toString() ?? '';
                  final targetType =
                      report['target_type']?.toString() ?? '';
                  final target = targets[targetId];
                  final pending =
                      report['status']?.toString() == 'pending';
                  // Resolved content: the reported message body (+ sender)
                  // or the reported user's name — never just a UUID
                  // fragment. Encrypted messages show the server-side
                  // placeholder, never plaintext (by design).
                  final String targetSummary;
                  final String? conversationId;
                  if (target == null) {
                    targetSummary = targetType == 'message'
                        ? 'رسالة محذوفة أو غير متوفرة.'
                        : targetType == 'user'
                            ? 'مستخدم محذوف أو غير متوفر.'
                            : 'هدف غير متوفر.';
                    conversationId = null;
                  } else if (target['kind'] == 'message') {
                    final body = target['body']?.toString() ?? '';
                    final shown = body.isEmpty
                        ? (target['message_type']?.toString() == 'text'
                            ? 'رسالة فارغة.'
                            : 'مرفق (${target['message_type']}).')
                        : body;
                    targetSummary =
                        '${target['sender_name']}: $shown';
                    final cid = target['conversation_id']?.toString() ?? '';
                    conversationId = cid.isEmpty ? null : cid;
                  } else {
                    targetSummary = target['name']?.toString() ?? 'مستخدم';
                    conversationId = null;
                  }
                  return ListTile(
                    leading:
                        const CircleAvatar(child: Icon(Icons.flag_outlined)),
                    title: Text(
                        '$reporterName • ${reportTargetLabel(targetType)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(report['reason']?.toString() ?? ''),
                        Text(targetSummary),
                        Text(
                            '${dateLabel(report['created_at']?.toString())} • ${reportStatusLabel(report['status']?.toString())}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54)),
                        Row(children: [
                          if (pending) ...[
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => onSetStatus(report, true),
                                child: const Text('مراجعة')),
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => onSetStatus(report, false),
                                child: const Text('تجاهل')),
                          ] else
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => onReopen(report),
                                child: const Text('إعادة فتح')),
                          if (conversationId != null)
                            TextButton(
                                onPressed: () => onOpenConversation(
                                    conversationId!,
                                    target?['sender_name']?.toString() ??
                                        'محادثة'),
                                child: const Text('فتح المحادثة')),
                        ]),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      );
}
