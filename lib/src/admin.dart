import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// True when the profile row marks the user as an admin.
bool isAdminProfile(Map<String, dynamic>? row) => row?['is_admin'] == true;

/// True when the profile row marks the user as banned.
bool isBannedProfile(Map<String, dynamic>? row) => row?['is_banned'] == true;

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
/// id is a non-empty UUID-shaped string.
bool isValidReportTarget(String? type, String? id) {
  if (type != 'post' && type != 'message' && type != 'user') return false;
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
      .select('id,display_name,username,is_admin,is_banned')
      .eq('id', uid)
      .maybeSingle();
  if (row == null) return null;
  return Map<String, dynamic>.from(row);
}

/// All reports with the reporter's profile embedded, pending first.
Future<List<Map<String, dynamic>>> loadReports() async {
  final rows = await Supabase.instance.client
      .from('reports')
      .select('*,profiles(display_name,username)')
      .order('created_at', ascending: false);
  return sortReports(rows.cast<Map<String, dynamic>>());
}

/// Mark a report as reviewed (admin-only, enforced server-side).
Future<void> reviewReport(String reportId) async {
  await Supabase.instance.client
      .from('reports')
      .update({'status': 'reviewed'}).eq('id', reportId);
}

/// Mark a report as dismissed (admin-only, enforced server-side).
Future<void> dismissReport(String reportId) async {
  await Supabase.instance.client
      .from('reports')
      .update({'status': 'dismissed'}).eq('id', reportId);
}

/// Ban or unban a user through the admin-only RPC. Admins never update
/// profiles directly from the client.
Future<void> setUserBanned(String userId, bool banned) async {
  await Supabase.instance.client.rpc('set_user_banned',
      params: {'target_user': userId, 'banned': banned});
}

/// Admin stats in one call: {'users': n, 'conversations': n, 'messages': n}.
Future<Map<String, dynamic>> loadAdminStats() async {
  final result = await Supabase.instance.client.rpc('admin_stats');
  if (result is Map) return Map<String, dynamic>.from(result);
  return {'users': 0, 'conversations': 0, 'messages': 0};
}

/// All user profiles, newest first.
Future<List<Map<String, dynamic>>> loadAllUsers() async {
  final rows = await Supabase.instance.client
      .from('profiles')
      .select('id,display_name,username,is_admin,is_banned,created_at')
      .order('created_at', ascending: false);
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
