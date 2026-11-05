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

class ChatPage extends StatefulWidget {
  final String conversationId, title;
  final String kind;
  final bool isAdmin;
  const ChatPage(
      {super.key,
      required this.conversationId,
      required this.title,
      this.kind = 'direct',
      this.isAdmin = true});
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
  final Set<String> _memberIds = {};
  bool _isGroup = false;

  // E2E encryption state (see lib/src/e2ee.dart for the honest limits).
  // Members' public keys, keyed by user id; null/empty means "no key yet".
  Map<String, String?> _memberPublicKeys = {};
  // Decrypted bodies of encrypted messages, keyed by message id.
  final Map<String, String> _decrypted = {};
  final Set<String> _decrypting = {};
  final Set<String> _decryptFailed = {};
  List<int>? _conversationKey;
  bool _conversationKeyLoaded = false;
  bool _keyLoading = false;
  bool _decryptRunning = false;

  @override
  void initState() {
    super.initState();
    _messagesStream = client.from('messages').stream(primaryKey: ['id'])
      .eq('conversation_id', widget.conversationId).order('created_at');
    _loadMembers();
    _ensureConversationKey();
  }

  /// Member display names, so group messages show who wrote them.
  /// Also loads members' E2E public keys. The public_key select fails
  /// when migration 012 has not been applied yet (unknown column), so
  /// fall back to the old select — names must keep working either way.
  Future<void> _loadMembers() async {
    try {
      List rows;
      try {
        rows = await client.from('conversation_members')
          .select('user_id,profiles(display_name,username,public_key)')
          .eq('conversation_id', widget.conversationId);
      } catch (_) {
        rows = await client.from('conversation_members')
          .select('user_id,profiles(display_name,username)')
          .eq('conversation_id', widget.conversationId);
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
        setState(() {
          _memberNames = names;
          _memberIds
            ..clear()
            ..addAll(ids);
          _memberPublicKeys = keys;
          _isGroup = names.length > 2;
        });
      }
    } catch (_) {
      // Names are a nicety; messages still work without them.
    }
  }

  /// Loads (or creates, when the conversation has none yet) this
  /// conversation's E2E key. Best-effort: a null key only means this chat
  /// sends/reads plaintext, it never blocks the chat itself.
  Future<void> _ensureConversationKey() async {
    if (_conversationKeyLoaded || _keyLoading) return;
    _keyLoading = true;
    try {
      final pair = await ensureKeyPair();
      try {
        await publishPublicKeyIfNeeded(pair: pair);
      } catch (_) {
        // Publishing must never block the chat (e.g. pre-migration 012).
      }
      final key = await loadOrCreateConversationKey(
          widget.conversationId, _memberPublicKeys);
      if (mounted) {
        setState(() {
          _conversationKey = key;
          _conversationKeyLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _conversationKeyLoaded = true);
    } finally {
      _keyLoading = false;
    }
  }

  /// Decrypts encrypted rows that arrived in the stream and are not yet
  /// cached, failed, or in flight. Runs after the frame (never setState
  /// in a loop, never re-decrypt a cached row) and only one run at a time.
  Future<void> _decryptPendingRows(List<Map<String, dynamic>> rows) async {
    if (_decryptRunning) return;
    final pending = rows.where((row) {
      if (!isEncryptedMessage(row)) return false;
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) return false;
      return !_decrypted.containsKey(id) &&
          !_decrypting.contains(id) &&
          !_decryptFailed.contains(id);
    }).toList();
    if (pending.isEmpty) return;
    if (!_conversationKeyLoaded) {
      await _ensureConversationKey();
      if (!mounted) return;
      // Key load triggers a rebuild, which re-schedules this step.
      return;
    }
    final key = _conversationKey;
    if (key == null) {
      // No key for this conversation (e.g. I joined after the key was
      // created and nobody re-wrapped for me): every pending encrypted
      // row is unreadable — show the failure note, not a spinner forever.
      if (mounted) {
        setState(() {
          for (final row in pending) {
            _decryptFailed.add(row['id'].toString());
          }
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

  /// Only channel admins may post; the RLS policy enforces this
  /// server-side, this guard is UX so a member never opens the picker
  /// or sends into a rejection.
  bool get _canPost =>
      canPostInConversation(widget.kind, widget.isAdmin ? 'admin' : 'member');

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
    if (otherId == null) return;
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
    }
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

  Future<void> sendAttachment() async {
    if (!_canPost) {
      _showReadOnlyNote();
      return;
    }
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
      if (_decryptFailed.contains(id) ||
          (_conversationKeyLoaded && _conversationKey == null)) {
        return const Text('تعذّر فك تشفير هذه الرسالة');
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
    if (body.isEmpty || sending || uid == null) return;
    if (body.length > 4000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحد الأقصى للرسالة 4000 حرف.')),
      );
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
        await _loadMembers();
        convKey = await loadOrCreateConversationKey(
            widget.conversationId, _memberPublicKeys);
        if (convKey != null) {
          try {
            await wrapKeyForMembers(
                widget.conversationId, convKey, _memberPublicKeys);
          } catch (_) {
            // Lazy re-wrap is best-effort; the message still goes out.
          }
          canEncrypt = canEncryptFor(_memberPublicKeys);
          if (mounted) {
            setState(() {
              _conversationKey = convKey;
              _conversationKeyLoaded = true;
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
        await client.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': uid,
          'body': body,
          'message_type': 'text',
        });
      }
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
      appBar: AppBar(
          actions: [
            // Voice/video calls are 1:1 only: direct chats get the buttons,
            // groups and channels get none.
            if (widget.kind == 'direct' && _otherUserId != null) ...[
              IconButton(
                tooltip: 'مكالمة صوتية',
                onPressed: () => _startCall('voice'),
                icon: const Icon(Icons.call),
              ),
              IconButton(
                tooltip: 'مكالمة فيديو',
                onPressed: () => _startCall('video'),
                icon: const Icon(Icons.videocam),
              ),
            ],
            if (widget.kind == 'direct' && _otherUserId != null)
              PopupMenuButton<String>(
                tooltip: 'خيارات',
                onSelected: (value) {
                  if (value == 'report_user') {
                    _showReportDialog(
                        targetType: 'user',
                        targetId: _otherUserId!,
                        title: 'الإبلاغ عن المستخدم');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'report_user',
                      child: Text('الإبلاغ عن المستخدم')),
                ],
              ),
          ],
          title: Row(children: [
        if (isChannelKind(widget.kind))
          const Row(children: [
            Icon(Icons.campaign_rounded),
            SizedBox(width: 8),
          ]),
        Expanded(child: Text(widget.title)),
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
            // Decryption is async but the rows render synchronously:
            // kick it off after the frame; _decryptPendingRows guards
            // against re-decrypting cached / in-flight rows.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _decryptPendingRows(rows);
            });
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
                return GestureDetector(
                  onLongPress: () => _showMessageActions(row),
                  child: Align(
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
                            _messageBody(row),
                          if (time != null)
                            Text(DateFormat('HH:mm').format(time.toLocal()),
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.black54)),
                        ]),
                  ),
                ),
                );
              },
            );
          },
        )),
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
