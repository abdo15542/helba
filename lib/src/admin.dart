import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// True when the profile row marks the user as an admin.
bool isAdminProfile(Map<String, dynamic>? row) => row?['is_admin'] == true;

/// True when the profile row marks the user as banned.
bool isBannedProfile(Map<String, dynamic>? row) => row?['is_banned'] == true;

/// The moment a mute expires, parsed defensively: missing, unparsable or
/// non-string values mean "not muted". The muted_until column is added by
/// the backend coordinator; until it exists the field is simply absent.
DateTime? mutedUntilOf(Map<String, dynamic>? row) {
  final raw = row?['muted_until'];
  if (raw is! String) return null;
  return DateTime.tryParse(raw);
}

/// True when the profile row marks the user as currently muted
/// (muted_until in the future). A past/missing value means not muted.
bool isMutedProfile(Map<String, dynamic>? row, [DateTime? now]) {
  final until = mutedUntilOf(row);
  if (until == null) return false;
  return until.isAfter(now ?? DateTime.now());
}

/// True when the profile row belongs to a user who may see the admin panel.
bool canSeeAdminPanel(Map<String, dynamic>? row) => isAdminProfile(row);

/// Arabic label for a report status. Unknown statuses fall back to the
/// pending label rather than showing a raw English value.
String reportStatusLabel(String? status) {
  switch (status) {
    case 'reviewed':
      return 'تمت المراجعة';
    case 'dismissed':
      return 'تم التجاهل';
    case 'pending':
    default:
      return 'قيد المراجعة';
  }
}

/// Arabic label for a report target type.
String reportTargetLabel(String? type) {
  switch (type) {
    case 'message':
      return 'رسالة';
    case 'user':
      return 'مستخدم';
    case 'post':
      return 'منشور';
    default:
      return type ?? '';
  }
}

/// A report target is valid when its type is one of the known kinds and its
/// id is a non-empty UUID-shaped string. 'post' is NOT accepted: Helba has
/// no posts feature, so no post report can ever be resolvable.
bool isValidReportTarget(String? type, String? id) {
  if (type != 'message' && type != 'user') return false;
  if (id == null || id.trim().isEmpty) return false;
  return RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      .hasMatch(id.trim());
}

/// Pending reports first, then newest first within each status group.
List<Map<String, dynamic>> sortReports(List<Map<String, dynamic>> rows) {
  final sorted = List<Map<String, dynamic>>.from(rows);
  int rank(Map<String, dynamic> row) =>
      row['status']?.toString() == 'pending' ? 0 : 1;
  sorted.sort((a, b) {
    final byStatus = rank(a).compareTo(rank(b));
    if (byStatus != 0) return byStatus;
    final aCreated = a['created_at']?.toString() ?? '';
    final bCreated = b['created_at']?.toString() ?? '';
    return bCreated.compareTo(aCreated);
  });
  return sorted;
}

// ---------------------------------------------------------------------------
// Supabase data functions (kept here so the admin screen stays thin).
// ---------------------------------------------------------------------------

/// The current user's profile row, or null when signed out / no row yet.
/// A missing row is treated by callers as not-admin / not-banned.
Future<Map<String, dynamic>?> loadMyProfile() async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return null;
  final row = await Supabase.instance.client
      .from('profiles')
      .select('id,display_name,username,is_admin,is_banned,muted_until')
      .eq('id', uid)
      .maybeSingle();
  if (row == null) return null;
  return Map<String, dynamic>.from(row);
}

/// All reports with the reporter's profile embedded, pending first.
/// Bounded: at most [limit] rows (default 100); the panel raises the
/// limit with "show more" instead of fetching the whole table.
Future<List<Map<String, dynamic>>> loadReports({int limit = 100}) async {
  final rows = await Supabase.instance.client
      .from('reports')
      .select(
          'id,reporter_id,target_type,target_id,reason,status,created_at,profiles(display_name,username)')
      .order('created_at', ascending: false)
      .limit(limit);
  return sortReports(rows.cast<Map<String, dynamic>>());
}

/// Resolves the reported content for a page of reports, batching the
/// lookups instead of one query per report. Returns a map keyed by
/// target id:
/// - message targets: {'kind': 'message', 'body': ..., 'sender_name': ...,
///   'conversation_id': ...} (body is the plaintext placeholder for
///   encrypted messages — the server never stores E2E plaintext);
/// - user targets: {'kind': 'user', 'name': ...}.
/// Targets that no longer exist (deleted message / user) are absent.
Future<Map<String, Map<String, dynamic>>> resolveReportTargets(
    List<Map<String, dynamic>> reports) async {
  final messageIds = <String>{};
  final userIds = <String>{};
  for (final report in reports) {
    final id = report['target_id']?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    if (report['target_type']?.toString() == 'message') {
      messageIds.add(id);
    } else if (report['target_type']?.toString() == 'user') {
      userIds.add(id);
    }
  }
  final resolved = <String, Map<String, dynamic>>{};
  final client = Supabase.instance.client;
  if (messageIds.isNotEmpty) {
    final rows = await client
        .from('messages')
        .select('id,conversation_id,sender_id,body,message_type')
        .inFilter('id', messageIds.toList());
    final messages = rows.cast<Map<String, dynamic>>();
    // Sender names in a second batch query: no embedded join, so this
    // never depends on guessing the messages->profiles FK name.
    final senderIds = messages
        .map((m) => m['sender_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final senderNames = <String, String>{};
    if (senderIds.isNotEmpty) {
      final profiles = await client
          .from('profiles')
          .select('id,display_name,username')
          .inFilter('id', senderIds.toList());
      for (final row in profiles.cast<Map<String, dynamic>>()) {
        final name =
            row['display_name']?.toString().trim().isNotEmpty == true
                ? row['display_name'].toString()
                : (row['username']?.toString().isNotEmpty == true
                    ? '@${row['username']}'
                    : 'مستخدم');
        senderNames[row['id'].toString()] = name;
      }
    }
    for (final row in messages) {
      resolved[row['id'].toString()] = {
        'kind': 'message',
        'body': row['body']?.toString() ?? '',
        'message_type': row['message_type']?.toString() ?? 'text',
        'sender_name':
            senderNames[row['sender_id']?.toString()] ?? 'مستخدم',
        'conversation_id': row['conversation_id']?.toString() ?? '',
      };
    }
  }
  if (userIds.isNotEmpty) {
    final rows = await client
        .from('profiles')
        .select('id,display_name,username')
        .inFilter('id', userIds.toList());
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final name = row['display_name']?.toString().trim().isNotEmpty == true
          ? row['display_name'].toString()
          : (row['username']?.toString().isNotEmpty == true
              ? '@${row['username']}'
              : 'مستخدم');
      resolved[row['id'].toString()] = {'kind': 'user', 'name': name};
    }
  }
  return resolved;
}

/// Sets a report's status and throws when no row matched, so a silent
/// no-op (wrong id / RLS denial) can never look like success.
Future<void> _setReportStatus(String reportId, String status) async {
  final updated = await Supabase.instance.client
      .from('reports')
      .update({'status': status}).eq('id', reportId).select('id');
  if ((updated as List).isEmpty) {
    throw StateError('Report $reportId was not updated');
  }
}

/// Mark a report as reviewed (admin-only, enforced server-side).
Future<void> reviewReport(String reportId) async {
  await _setReportStatus(reportId, 'reviewed');
}

/// Mark a report as dismissed (admin-only, enforced server-side).
Future<void> dismissReport(String reportId) async {
  await _setReportStatus(reportId, 'dismissed');
}

/// Reopen a reviewed/dismissed report back to pending (undo).
Future<void> reopenReport(String reportId) async {
  await _setReportStatus(reportId, 'pending');
}

/// Ban or unban a user through the admin-only RPC. Admins never update
/// profiles directly from the client.
Future<void> setUserBanned(String userId, bool banned) async {
  await Supabase.instance.client.rpc('set_user_banned',
      params: {'target_user': userId, 'banned': banned});
}

/// Mute or unmute a user through the admin-only RPC.
/// Exact RPC contract assumed here (backend coordinator to match):
///   rpc 'set_user_muted'
///   params: {'p_target_user': `<uuid>`, 'p_muted_until': `<ISO-8601 string | null>`}
/// Pass mutedUntil == null to unmute. Throws when the RPC is not deployed
/// yet (or the caller is not an admin); callers surface that error.
/// NOTE: the muted_until column + this RPC are backend-owned and may not
/// exist yet — this function must only be called from a try/catch that
/// shows the failure (see AdminPanelPage._setMuted).
Future<void> setUserMuted(String userId, DateTime? mutedUntil) async {
  await Supabase.instance.client.rpc('set_user_muted', params: {
    'p_target_user': userId,
    'p_muted_until': mutedUntil?.toIso8601String(),
  });
}

/// Admin stats in one call: {'users': n, 'conversations': n, 'messages': n}.
Future<Map<String, dynamic>> loadAdminStats() async {
  final result = await Supabase.instance.client.rpc('admin_stats');
  if (result is Map) return Map<String, dynamic>.from(result);
  return {'users': 0, 'conversations': 0, 'messages': 0};
}

/// All user profiles, newest first. Bounded to [limit] rows (default 100).
/// When [query] is non-empty, filters server-side by username or
/// display_name (case-insensitive). Escape % / _ / \ so a search string
/// can never act as a LIKE wildcard.
String escapeLikePattern(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

Future<List<Map<String, dynamic>>> loadAllUsers(
    {int limit = 100, String? query}) async {
  // NOTE: muted_until is deliberately NOT selected here: the column is
  // added by the backend coordinator and selecting a missing column
  // would fail the whole query. Once it exists, add it to this select
  // so the panel can show the muted state from the loaded row.
  // The .or() filter must come before .order(): order() returns a
  // PostgrestTransformBuilder, which has no .or() method.
  final q = query?.trim() ?? '';
  final PostgrestFilterBuilder<List<Map<String, dynamic>>> filtered;
  final base = Supabase.instance.client
      .from('profiles')
      .select('id,display_name,username,is_admin,is_banned,muted_until,created_at');
  if (q.isNotEmpty) {
    final pattern = '%${escapeLikePattern(q)}%';
    filtered = base.or('username.ilike.$pattern,display_name.ilike.$pattern');
  } else {
    filtered = base;
  }
  final rows = await filtered
      .order('created_at', ascending: false)
      .limit(limit);
  return rows.cast<Map<String, dynamic>>();
}

/// File a report. The reporter is always the current user.
Future<void> submitReport({
  required String targetType,
  required String targetId,
  required String reason,
}) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) throw StateError('Authentication required');
  if (!isValidReportTarget(targetType, targetId)) {
    throw ArgumentError('Invalid report target');
  }
  await Supabase.instance.client.from('reports').insert({
    'reporter_id': uid,
    'target_type': targetType,
    'target_id': targetId,
    'reason': reason.trim().isEmpty ? 'أخرى' : reason.trim(),
  });
}
