import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin.dart';
import 'config.dart';

class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});
  @override
  State<AdminPanelPage> createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends State<AdminPanelPage> {
  late Future<Map<String, dynamic>> _statsFuture;
  late Future<List<Map<String, dynamic>>> _usersFuture;
  late Future<List<Map<String, dynamic>>> _reportsFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  void _loadAll() {
    _statsFuture = loadAdminStats();
    _usersFuture = loadAllUsers();
    _reportsFuture = loadReports();
  }

  Future<void> _refresh() async {
    final stats = loadAdminStats();
    final users = loadAllUsers();
    final reports = loadReports();
    if (mounted) {
      setState(() {
        _statsFuture = stats;
        _usersFuture = users;
        _reportsFuture = reports;
      });
    }
    try {
      await Future.wait([stats, users, reports]);
    } catch (_) {
      // Each tab's FutureBuilder already surfaces its own error.
    }
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

  Future<void> _setReportStatus(
      Map<String, dynamic> report, bool reviewed) async {
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

  String _dateLabel(String? raw) {
    final parsed = DateTime.tryParse(raw ?? '');
    if (parsed == null) return '';
    return DateFormat('yyyy-MM-dd').format(parsed.toLocal());
  }

  @override
  Widget build(BuildContext context) {
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
            onSetBanned: _setBanned,
          ),
          _ReportsTab(
            future: _reportsFuture,
            busy: _busy,
            dateLabel: _dateLabel,
            onSetStatus: _setReportStatus,
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

class _UsersTab extends StatelessWidget {
  final Future<List<Map<String, dynamic>>> future;
  final String? myId;
  final bool busy;
  final String Function(String?) dateLabel;
  final Future<void> Function(Map<String, dynamic>, bool) onSetBanned;
  const _UsersTab({
    required this.future,
    required this.myId,
    required this.busy,
    required this.dateLabel,
    required this.onSetBanned,
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
            return const Center(child: Text('تعذر تحميل المستخدمين.'));
          }
          final users = snap.data ?? [];
          if (users.isEmpty) {
            return const Center(child: Text('لا يوجد مستخدمون.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: users.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final user = users[i];
              final isSelf = user['id']?.toString() == myId;
              final banned = isBannedProfile(user);
              final displayName =
                  user['display_name']?.toString().trim().isNotEmpty == true
                      ? user['display_name'].toString()
                      : 'مستخدم';
              final username = user['username']?.toString() ?? '';
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Row(children: [
                  Expanded(
                      child: Text(displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  if (isAdminProfile(user))
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Chip(
                          label: Text('مشرف', style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact),
                    ),
                  if (banned)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Chip(
                          label:
                              Text('محظور', style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact),
                    ),
                ]),
                subtitle: Text(
                    '@$username${dateLabel(user['created_at']?.toString()).isEmpty ? '' : ' • ${dateLabel(user['created_at']?.toString())}'}'),
                trailing: TextButton(
                  onPressed: (busy || isSelf)
                      ? null
                      : () => onSetBanned(user, !banned),
                  child: Text(banned ? 'إلغاء الحظر' : 'حظر'),
                ),
              );
            },
          );
        },
      );
}

class _ReportsTab extends StatelessWidget {
  final Future<List<Map<String, dynamic>>> future;
  final bool busy;
  final String Function(String?) dateLabel;
  final Future<void> Function(Map<String, dynamic>, bool) onSetStatus;
  const _ReportsTab({
    required this.future,
    required this.busy,
    required this.dateLabel,
    required this.onSetStatus,
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
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: reports.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
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
              final pending = report['status']?.toString() == 'pending';
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.flag_outlined)),
                title: Text(
                    '$reporterName • ${reportTargetLabel(report['target_type']?.toString())}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(report['reason']?.toString() ?? ''),
                    Text(
                        '${targetId.length >= 8 ? targetId.substring(0, 8) : targetId} • ${dateLabel(report['created_at']?.toString())} • ${reportStatusLabel(report['status']?.toString())}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                    if (pending)
                      Row(children: [
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
                      ]),
                  ],
                ),
              );
            },
          );
        },
      );
}
