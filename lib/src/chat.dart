import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

class ChatPage extends StatefulWidget {
  final String conversationId, title;
  const ChatPage({super.key, required this.conversationId, required this.title});
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
  // the list with a loading spinner.
  late final Stream<List<Map<String, dynamic>>> _messagesStream;
  Map<String, String> _memberNames = {};
  bool _isGroup = false;

  @override
  void initState() {
    super.initState();
    _messagesStream = client.from('messages').stream(primaryKey: ['id'])
      .eq('conversation_id', widget.conversationId).order('created_at');
    _loadMembers();
  }

  /// Member display names, so group messages show who wrote them.
  Future<void> _loadMembers() async {
    try {
      final rows = await client.from('conversation_members')
        .select('user_id,profiles(display_name,username)')
        .eq('conversation_id', widget.conversationId);
      final names = <String, String>{};
      for (final row in rows as List) {
        if (row is! Map) continue;
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
          _isGroup = names.length > 2;
        });
      }
    } catch (_) {
      // Names are a nicety; messages still work without them.
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    if (extent > 0) _scroll.jumpTo(extent);
  }

  @override
  void dispose() {
    input.dispose();
    _scroll.dispose();
    super.dispose();
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

  Future<void> sendAttachment() async {
    if (sending) return;
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
      final uid = client.auth.currentUser!.id;
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
    } catch (_) {
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

  Future<void> send() async {
    final body = input.text.trim();
    final uid = client.auth.currentUser?.id;
    if (body.isEmpty || sending || uid == null) return;
    if (body.length > 4000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحد الأقصى للرسالة 4000 حرف.')),
      );
      return;
    }
    setState(() => sending = true);
    try {
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': body,
        'message_type': 'text',
      });
      input.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر إرسال الرسالة.')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _messagesStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('تعذر تحميل الرسائل'));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const Center(child: Text('ابدأ المحادثة برسالة ترحيب 👋'));
            }
            if (rows.length != _lastMessageCount) {
              _lastMessageCount = rows.length;
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _scrollToBottom());
            }
            return ListView.builder(
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
                return Align(
                  alignment:
                      mine ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                        color: mine
                            ? const Color(0xFFDDF3E6)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(16)),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!mine && _isGroup && senderName != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(senderName,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: green)),
                            ),
                          if (row['attachment_path'] != null)
                            InkWell(
                              onTap: () =>
                                  openAttachment(row['attachment_path'].toString()),
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
                            )
                          else
                            Text(row['body']?.toString() ?? ''),
                          if (time != null)
                            Text(DateFormat('HH:mm').format(time.toLocal()),
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.black54)),
                        ]),
                  ),
                );
              },
            );
          },
        )),
        SafeArea(
            child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(children: [
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
          ]),
        )),
      ]),
    );
  }
}
