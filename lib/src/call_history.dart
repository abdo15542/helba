import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'calls.dart';

// ---------------------------------------------------------------------------
// Call history ("المكالمات"): past calls from the `calls` table where I am
// caller or callee, newest first. Tapping an entry calls that person
// back. The table is the history by design (migration 010): the caller
// inserts the row on start, and whichever side ends the call writes the
// final status plus `ended_at` — so no schema change was needed here.
// ---------------------------------------------------------------------------

/// One row of call history, mapped from a `calls` row. Pure: unit-tested.
class CallHistoryEntry {
  final String id;
  final String otherUserId;
  final String otherName;
  final String callType;
  final bool isOutgoing;
  final String status;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const CallHistoryEntry({
    required this.id,
    required this.otherUserId,
    required this.otherName,
    required this.callType,
    required this.isOutgoing,
    required this.status,
    this.startedAt,
    this.endedAt,
  });

  /// Call duration (ended_at − started_at), only for answered calls
  /// (status `completed`): a missed / declined / cancelled call has an
  /// ended_at too (when it stopped ringing), but that is ring time, not
  /// talk time, and showing it as a duration would be misleading.
  /// Null for ringing / missed / declined calls.
  Duration? get duration {
    if (status != 'completed') return null;
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final value = end.difference(start);
    return value.isNegative ? null : value;
  }

  /// True when this was an incoming call the user never answered.
  bool get isMissed => !isOutgoing && status == 'missed';
}

/// Maps one `calls` row to a history entry, or null when the row is
/// unusable (missing id / participants). [names] maps user id to the
/// display name the page resolved from profiles; a missing name falls
/// back to 'مستخدم' rather than a blank tile. Pure: unit-tested.
CallHistoryEntry? parseCallHistoryRow(
  Map<String, dynamic> row,
  String myId,
  Map<String, String> names,
) {
  final id = row['id']?.toString() ?? '';
  final callerId = row['caller_id']?.toString() ?? '';
  final calleeId = row['callee_id']?.toString() ?? '';
  if (id.isEmpty || callerId.isEmpty || calleeId.isEmpty) return null;
  if (callerId != myId && calleeId != myId) return null;
  final isOutgoing = callerId == myId;
  final otherUserId = isOutgoing ? calleeId : callerId;
  final otherName = names[otherUserId]?.trim().isNotEmpty == true
      ? names[otherUserId]!.trim()
      : 'مستخدم';
  final callType = row['type']?.toString() == 'video' ? 'video' : 'voice';
  return CallHistoryEntry(
    id: id,
    otherUserId: otherUserId,
    otherName: otherName,
    callType: callType,
    isOutgoing: isOutgoing,
    status: row['status']?.toString() ?? '',
    startedAt: DateTime.tryParse(row['started_at']?.toString() ?? ''),
    endedAt: DateTime.tryParse(row['ended_at']?.toString() ?? ''),
  );
}

/// Relative Arabic time for a history row: 'اليوم HH:mm', 'أمس HH:mm',
/// otherwise 'dd/MM/yyyy HH:mm'. Pure ([now] is injectable for tests).
String formatCallHistoryTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(time.year, time.month, time.day);
  final difference = today.difference(day).inDays;
  final hm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (difference == 0) return 'اليوم $hm';
  if (difference == 1) return 'أمس $hm';
  final date =
      '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}/${time.year}';
  return '$date $hm';
}

class CallHistoryPage extends StatefulWidget {
  const CallHistoryPage({super.key});
  @override
  State<CallHistoryPage> createState() => _CallHistoryPageState();
}

class _CallHistoryPageState extends State<CallHistoryPage> {
  late Future<List<CallHistoryEntry>> _historyFuture;
  bool _callingBack = false;

  @override
  void initState() {
    super.initState();
    _historyFuture = loadCallHistory();
  }

  /// Loads my call history: `calls` rows where I am caller or callee,
  /// newest first, with the other party's display name resolved from
  /// profiles in a second query (no FK-embedding assumption).
  Future<List<CallHistoryEntry>> loadCallHistory() async {
    final client = Supabase.instance.client;
    final myId = client.auth.currentUser?.id;
    if (myId == null) return [];
    final rows = await client
        .from('calls')
        .select('id,caller_id,callee_id,type,status,started_at,ended_at')
        .or('caller_id.eq.$myId,callee_id.eq.$myId')
        .order('started_at', ascending: false)
        .limit(100)
        .timeout(const Duration(seconds: 15));
    final parsed = rows.cast<Map<String, dynamic>>();
    final otherIds = <String>{};
    for (final row in parsed) {
      final callerId = row['caller_id']?.toString() ?? '';
      final calleeId = row['callee_id']?.toString() ?? '';
      if (callerId.isNotEmpty && callerId != myId) otherIds.add(callerId);
      if (calleeId.isNotEmpty && calleeId != myId) otherIds.add(calleeId);
    }
    final names = <String, String>{};
    if (otherIds.isNotEmpty) {
      try {
        final profiles = await client
            .from('profiles')
            .select('id,display_name,username')
            .inFilter('id', otherIds.toList())
            .timeout(const Duration(seconds: 15));
        for (final profile in profiles.cast<Map<String, dynamic>>()) {
          final id = profile['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final display = profile['display_name']?.toString().trim() ?? '';
          final username = profile['username']?.toString().trim() ?? '';
          names[id] = display.isNotEmpty
              ? display
              : (username.isNotEmpty ? '@$username' : 'مستخدم');
        }
      } catch (_) {
        // Names stay missing: entries fall back to 'مستخدم'.
      }
    }
    final entries = <CallHistoryEntry>[];
    for (final row in parsed) {
      final entry = parseCallHistoryRow(row, myId, names);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Future<void> _refresh() async {
    final future = loadCallHistory();
    await future;
    if (mounted) setState(() => _historyFuture = future);
  }

  /// Calls the other party back (same flow as the chat screen's call
  /// buttons): starts the call, then opens the call screen. A failed
  /// start (permissions, or a call already in progress) shows a
  /// SnackBar instead of opening a dead screen.
  Future<void> _callBack(CallHistoryEntry entry) async {
    if (_callingBack) return;
    _callingBack = true;
    try {
      final callId = await CallService.instance.startCall(
        calleeId: entry.otherUserId,
        calleeName: entry.otherName,
        callType: entry.callType,
      );
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
                    peerId: entry.otherUserId,
                    peerName: entry.otherName,
                    callType: entry.callType,
                    isCaller: true,
                  )));
      // The call just ended: refresh so it appears in the list.
      if (mounted) _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('تعذّر بدء المكالمة. تحقق من الاتصال وحاول مجدداً.')),
        );
      }
    } finally {
      _callingBack = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المكالمات')),
        body: FutureBuilder<List<CallHistoryEntry>>(
          future: _historyFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذّر تحميل سجل المكالمات.'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            final entries = snapshot.data ?? [];
            if (entries.isEmpty) {
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('لا توجد مكالمات بعد.')),
                ]),
              );
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final duration = entry.duration;
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        entry.otherName.isNotEmpty
                            ? entry.otherName.characters.first
                            : '?',
                      ),
                    ),
                    title: Text(entry.otherName),
                    subtitle: Row(children: [
                      Icon(
                        entry.isOutgoing
                            ? Icons.call_made
                            : Icons.call_received,
                        size: 14,
                        color: entry.isMissed ? Colors.red : Colors.black54,
                      ),
                      const SizedBox(width: 4),
                      Text(callTypeLabel(entry.callType)),
                      const SizedBox(width: 4),
                      Text('• ${callStatusLabel(entry.status)}'),
                      if (duration != null)
                        Text(' • ${formatCallDuration(duration)}'),
                    ]),
                    trailing: entry.startedAt == null
                        ? null
                        : Text(
                            formatCallHistoryTime(entry.startedAt!),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                    onTap: () => _callBack(entry),
                  );
                },
              ),
            );
          },
        ),
      );
}
