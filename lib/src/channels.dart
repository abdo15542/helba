import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// True when the conversation kind is a broadcast channel.
bool isChannelKind(String? kind) => kind == 'channel';

/// Who may post: in a channel only admins post; in a direct chat or a
/// group every member may post. An unknown kind defaults to allowed, so a
/// future kind never silently locks the composer.
bool canPostInConversation(String? kind, String? role) {
  if (kind == 'channel') return role == 'admin';
  return true;
}

/// Arabic label for a conversation kind.
String channelSubtitle(String? kind) {
  switch (kind) {
    case 'channel':
      return 'قناة';
    case 'group':
      return 'مجموعة';
    default:
      return 'محادثة فردية';
  }
}

/// The current user's role in a conversation row, from its embedded
/// conversation_members list. Defaults to 'member'.
String roleInConversation(Map<String, dynamic> row, String? myUserId) {
  final members = row['conversation_members'] as List<dynamic>? ?? [];
  for (final m in members) {
    if (m is Map && m['user_id']?.toString() == myUserId) {
      final role = m['role']?.toString();
      if (role == 'admin') return 'admin';
      if (role == 'member') return 'member';
      return 'member';
    }
  }
  return 'member';
}

/// Public channels the user has not joined yet. Rows carry the conversation
/// plus its nested members; a row is joinable when it is a public channel
/// and none of its members is the current user.
List<Map<String, dynamic>> joinableChannels(
    List<Map<String, dynamic>> rows, String? myUserId) {
  return rows.where((row) {
    if (row['kind']?.toString() != 'channel') return false;
    if (row['is_public'] != true) return false;
    final members = row['conversation_members'] as List<dynamic>? ?? [];
    return !members.any((m) =>
        m is Map && m['user_id']?.toString() == myUserId);
  }).toList();
}

// ---------------------------------------------------------------------------
// Loading.
// ---------------------------------------------------------------------------

/// All public channels with their members, newest first. The caller filters
/// out already-joined ones with [joinableChannels].
Future<List<Map<String, dynamic>>> loadPublicChannels() async {
  final rows = await Supabase.instance.client
      .from('conversations')
      .select('id,kind,title,is_public,created_at,conversation_members(user_id)')
      .eq('kind', 'channel')
      .eq('is_public', true)
      .order('created_at', ascending: false);
  return rows.cast<Map<String, dynamic>>();
}

/// Joins a public channel; returns its id. Idempotent on the server: joining
/// a channel the user already belongs to returns the id without error.
Future<String> joinChannel(String channelId) async {
  final result = await Supabase.instance.client
      .rpc('join_channel', params: {'channel_id': channelId});
  return result.toString();
}

// ---------------------------------------------------------------------------
// Public channel directory (bottom sheet opened from the inbox AppBar).
// ---------------------------------------------------------------------------

class ChannelDirectorySheet extends StatefulWidget {
  const ChannelDirectorySheet({super.key});
  @override
  State<ChannelDirectorySheet> createState() => _ChannelDirectorySheetState();
}

class _ChannelDirectorySheetState extends State<ChannelDirectorySheet> {
  late Future<List<Map<String, dynamic>>> _channelsFuture;
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _channelsFuture = loadPublicChannels();
  }

  Future<void> _join(Map<String, dynamic> channel) async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final id = await joinChannel(channel['id'].toString());
      if (!mounted) return;
      final title = channel['title']?.toString().trim().isNotEmpty == true
          ? channel['title'].toString()
          : 'قناة';
      Navigator.pop(context);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversationId: id, title: title, kind: 'channel')));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'تعذر الانضمام إلى القناة. تحقق من الاتصال.');
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = Supabase.instance.client.auth.currentUser?.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Row(children: [
          Icon(Icons.campaign_outlined),
          SizedBox(width: 8),
          Text('القنوات العامة',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 10),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        Flexible(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _channelsFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('تعذر تحميل القنوات العامة.'));
              }
              final joinable = joinableChannels(snap.data ?? [], myUserId);
              if (joinable.isEmpty) {
                return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('لا توجد قنوات عامة بعد.'));
              }
              return ListView(
                  shrinkWrap: true,
                  children: joinable.map((channel) {
                    final members =
                        channel['conversation_members'] as List<dynamic>? ??
                            [];
                    final title =
                        channel['title']?.toString().trim().isNotEmpty == true
                            ? channel['title'].toString()
                            : 'قناة';
                    return ListTile(
                      leading: const CircleAvatar(
                          child: Icon(Icons.campaign_rounded)),
                      title: Text(title,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${members.length} عضو'),
                      trailing: FilledButton(
                        onPressed: _joining ? null : () => _join(channel),
                        child: const Text('انضمام'),
                      ),
                    );
                  }).toList());
            },
          ),
        ),
      ]),
    );
  }
}
