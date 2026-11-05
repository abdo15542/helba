import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

const green = Color(0xFF087A4B);
const secureStore = FlutterSecureStorage();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://mpgnybncdiaaohjaqejq.supabase.co');
  const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_IZ-P_b8LjdDfjATffyqqDg_yJOu9-Og');
  if (url.isNotEmpty && key.isNotEmpty) {
    await Supabase.initialize(url: url, publishableKey: key);
  }
  runApp(const HelbaApp());
}

class HelbaApp extends StatelessWidget {
  const HelbaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'هلبة',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: green),
      scaffoldBackgroundColor: const Color(0xFFF5F8F6),
      fontFamily: 'Arial',
    ),
    home: Directionality(textDirection: ui.TextDirection.rtl, child: const AuthGate()),
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? boundEmail;
  bool loading = true;
  bool configured = false;

  @override
  void initState() {
    super.initState();
    configured = Supabase.instance.isInitialized;
    _load();
  }

  Future<void> _load() async {
    boundEmail = await secureStore.read(key: 'helba_bound_email');
    if (mounted) setState(() => loading = false);
  }

  Future<void> _bind(String email) async {
    final normalized = email.trim().toLowerCase();
    await secureStore.write(key: 'helba_bound_email', value: normalized);
    if (mounted) setState(() => boundEmail = normalized);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!configured) return const SetupPage();
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) return LoginPage(boundEmail: boundEmail, onSignedIn: _bind);
        final email = (user.email ?? '').toLowerCase();
        if (boundEmail != null && boundEmail != email) {
          return Scaffold(body: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48, color: green),
              const SizedBox(height: 12),
              const Text('هذا التثبيت مرتبط ببريد آخر', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('تسجيل الخروج')),
            ]),
          )));
        }
        if (boundEmail == null) WidgetsBinding.instance.addPostFrameCallback((_) => _bind(email));
        return const InboxPage();
      },
    );
  }
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Padding(
    padding: EdgeInsets.all(24),
    child: Text('أضف SUPABASE_URL وSUPABASE_ANON_KEY لتفعيل هلبة.', textAlign: TextAlign.center),
  )));
}

class LoginPage extends StatefulWidget {
  final String? boundEmail;
  final Future<void> Function(String) onSignedIn;
  const LoginPage({super.key, required this.boundEmail, required this.onSignedIn});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool signup = false, busy = false, hidePassword = true;
  String? error, message;

  @override
  void initState() {
    super.initState();
    if (widget.boundEmail != null) email.text = widget.boundEmail!;
  }
  @override
  void dispose() { email.dispose(); password.dispose(); super.dispose(); }

  Future<void> submit() async {
    final e = email.text.trim().toLowerCase();
    if (!e.contains('@') || password.text.length < 8) {
      setState(() => error = 'أدخل بريداً صحيحاً وكلمة مرور من 8 أحرف على الأقل.');
      return;
    }
    if (widget.boundEmail != null && widget.boundEmail != e) {
      setState(() => error = 'هذا الجهاز مرتبط بالبريد ${widget.boundEmail} ولا يقبل بريداً آخر.');
      return;
    }
    setState(() { busy = true; error = null; message = null; });
    try {
      final auth = Supabase.instance.client.auth;
      if (signup) {
        await auth.signUp(email: e, password: password.text);
        setState(() => message = 'أرسلنا رابط تأكيد إلى بريدك الإلكتروني.');
      } else {
        final result = await auth.signInWithPassword(email: e, password: password.text);
        if (result.user?.emailConfirmedAt == null) {
          await auth.signOut();
          setState(() => error = 'أكد بريدك الإلكتروني أولاً من الرسالة التي وصلتك.');
        } else {
          await widget.onSignedIn(e);
        }
      }
    } on AuthException catch (ex) {
      setState(() => error = ex.message);
    } catch (_) {
      setState(() => error = 'تعذر الاتصال بالخدمة. حاول مجدداً.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.forum_rounded, color: green, size: 68),
          const SizedBox(height: 12),
          const Text('هلبة', textAlign: TextAlign.center, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900)),
          const Text('تواصل يجمعنا', textAlign: TextAlign.center),
          const SizedBox(height: 36),
          Text(signup ? 'إنشاء حساب جديد' : 'تسجيل الدخول', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'البريد الإلكتروني', prefixIcon: Icon(Icons.email_outlined), border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: password, obscureText: hidePassword, decoration: InputDecoration(labelText: 'كلمة المرور', prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(icon: Icon(hidePassword ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => hidePassword = !hidePassword)), border: const OutlineInputBorder())),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
          if (message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!, style: const TextStyle(color: green))),
          const SizedBox(height: 18),
          FilledButton(onPressed: busy ? null : submit, child: busy ? const CircularProgressIndicator() : Text(signup ? 'إنشاء الحساب' : 'دخول')),
          TextButton(onPressed: busy ? null : () => setState(() { signup = !signup; error = null; message = null; }), child: Text(signup ? 'لديك حساب؟ سجل الدخول' : 'ليس لديك حساب؟ أنشئ حساباً')),
          TextButton(onPressed: busy ? null : () async {
            final e = email.text.trim().toLowerCase();
            if (!e.contains('@')) {
              setState(() => error = 'أدخل بريدك الإلكتروني أولاً.');
              return;
            }
            setState(() { busy = true; error = null; message = null; });
            try {
              await Supabase.instance.client.auth.resetPasswordForEmail(e);
              if (mounted) setState(() => message = 'إذا كان البريد مسجلاً فستصلك رسالة استعادة كلمة المرور.');
            } on AuthException catch (ex) {
              if (mounted) setState(() => error = ex.message);
            } catch (_) {
              if (mounted) setState(() => error = 'تعذر إرسال رسالة الاستعادة. تحقق من الاتصال وحاول مجدداً.');
            } finally {
              if (mounted) setState(() => busy = false);
            }
          }, child: const Text('نسيت كلمة المرور؟')),
        ],
      )),
    ))),
  );
}

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final search = TextEditingController();
  String query = '';
  @override
  void dispose() { search.dispose(); super.dispose(); }

  Future<List<Map<String, dynamic>>> loadChats() async {
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final rows = await Supabase.instance.client.from('conversation_members')
      .select('conversation_id, conversations(id,kind,title,updated_at)')
      .eq('user_id', uid);
    return rows.cast<Map<String, dynamic>>();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('هلبة', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, color: green)),
      actions: [IconButton(onPressed: () => Supabase.instance.client.auth.signOut(), icon: const Icon(Icons.logout))],
    ),
    floatingActionButton: FloatingActionButton.extended(
      backgroundColor: green, foregroundColor: Colors.white,
      onPressed: () => showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => const NewChatSheet()),
      icon: const Icon(Icons.add_comment_outlined), label: const Text('محادثة جديدة'),
    ),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: TextField(
        controller: search, onChanged: (v) => setState(() => query = v),
        decoration: InputDecoration(hintText: 'ابحث في محادثاتك', prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none)),
      )),
      Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(
        future: loadChats(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text('تعذر تحميل المحادثات: ${snap.error}'));
          final chats = (snap.data ?? []).where((r) {
            final c = r['conversations'] as Map<String, dynamic>?;
            return (c?['title']?.toString().toLowerCase() ?? '').contains(query.toLowerCase());
          }).toList();
          if (chats.isEmpty) return const _EmptyInbox();
          return ListView.separated(
            itemCount: chats.length, separatorBuilder: (_, __) => const Divider(indent: 84, height: 1),
            itemBuilder: (context, i) {
              final c = chats[i]['conversations'] as Map<String, dynamic>;
              return ListTile(
                leading: const CircleAvatar(backgroundColor: Color(0xFFE1F1E8), child: Icon(Icons.person, color: green)),
                title: Text(c['title']?.toString().isNotEmpty == true ? c['title'] : 'محادثة جديدة', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('افتح المحادثة لعرض الرسائل'),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: c['id'].toString(), title: c['title']?.toString() ?? 'محادثة'))),
              );
            },
          );
        },
      )),
    ]),
  );
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();
  @override
  Widget build(BuildContext context) => const Center(child: Padding(
    padding: EdgeInsets.all(32),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.chat_bubble_outline, size: 58, color: green),
      SizedBox(height: 12),
      Text('لا توجد محادثات بعد', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
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
  bool creatingGroup = false;
  String? error;

  Future<void> findUsers(String value) async {
    if (value.trim().length < 2) { setState(() => users = []); return; }
    setState(() => busy = true);
    try {
      final me = Supabase.instance.client.auth.currentUser!.id;
      final result = await Supabase.instance.client.from('profiles')
        .select('id,display_name,username')
        .neq('id', me)
        .or('username.ilike.%$value%,display_name.ilike.%$value%')
        .limit(20);
      setState(() { users = result.cast<Map<String, dynamic>>(); error = null; });
    } catch (_) { setState(() => error = 'تعذر البحث عن المستخدمين.'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> createGroup() async {
    if (groupTitle.text.trim().length < 2 || selectedIds.isEmpty) {
      setState(() => error = 'اكتب اسم المجموعة واختر عضواً واحداً على الأقل.');
      return;
    }
    setState(() { busy = true; error = null; });
    try {
      final result = await Supabase.instance.client.rpc(
        'create_group_conversation',
        params: {'group_title': groupTitle.text.trim(), 'member_ids': selectedIds.toList()},
      );
      if (!mounted) return;
      final title = groupTitle.text.trim();
      Navigator.pop(context);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: result.toString(), title: title)));
    } catch (_) {
      if (mounted) setState(() => error = 'تعذر إنشاء المجموعة. تأكد من تطبيق ترحيل قاعدة البيانات رقم 002.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startChat(Map<String, dynamic> user) async {
    setState(() => busy = true);
    try {
      final result = await Supabase.instance.client.rpc('create_direct_conversation', params: {'target_user': user['id']});
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: result.toString(), title: user['display_name']?.toString() ?? 'محادثة')));
    } catch (_) { setState(() => error = 'تعذر إنشاء المحادثة. تحقق من إعداد قاعدة البيانات.'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  @override
  void dispose() { controller.dispose(); groupTitle.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Text(creatingGroup ? 'إنشاء مجموعة' : 'محادثة جديدة', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold))),
        TextButton.icon(
          onPressed: () => setState(() { creatingGroup = !creatingGroup; selectedIds.clear(); error = null; }),
          icon: Icon(creatingGroup ? Icons.person_outline : Icons.groups_outlined),
          label: Text(creatingGroup ? 'محادثة فردية' : 'مجموعة'),
        ),
      ]),
      if (creatingGroup) ...[
        const SizedBox(height: 10),
        TextField(controller: groupTitle, decoration: const InputDecoration(labelText: 'اسم المجموعة', border: OutlineInputBorder())),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 8),
      TextField(controller: controller, onChanged: findUsers, decoration: const InputDecoration(hintText: 'ابحث بالاسم أو اسم المستخدم', prefixIcon: Icon(Icons.search), border: OutlineInputBorder())),
      if (busy) const Padding(padding: EdgeInsets.all(10), child: LinearProgressIndicator()),
      if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
      Flexible(child: ListView(shrinkWrap: true, children: users.map((u) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: Text(u['display_name']?.toString() ?? ''),
        subtitle: Text('@${u['username'] ?? ''}'),
        trailing: creatingGroup ? Checkbox(
          value: selectedIds.contains(u['id'].toString()),
          onChanged: (checked) => setState(() {
            final id = u['id'].toString();
            if (checked == true) { selectedIds.add(id); } else { selectedIds.remove(id); }
          }),
        ) : null,
        onTap: () {
          if (creatingGroup) {
            setState(() {
              final id = u['id'].toString();
              if (!selectedIds.add(id)) selectedIds.remove(id);
            });
          } else {
            startChat(u);
          }
        },
      )).toList())),
      if (creatingGroup) Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: busy ? null : createGroup,
          icon: const Icon(Icons.group_add_outlined),
          label: Text('إنشاء المجموعة (${selectedIds.length})'),
        )),
      ),
    ]),
  );
}

class ChatPage extends StatefulWidget {
  final String conversationId, title;
  const ChatPage({super.key, required this.conversationId, required this.title});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  bool sending = false;
  final client = Supabase.instance.client;


  String? _mimeFor(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'webp': return 'image/webp';
      case 'gif': return 'image/gif';
      case 'mp4': return 'video/mp4';
      case 'mov': return 'video/quicktime';
      case 'mp3': return 'audio/mpeg';
      case 'm4a': return 'audio/mp4';
      case 'aac': return 'audio/aac';
      case 'ogg': return 'audio/ogg';
      case 'wav': return 'audio/wav';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'zip': return 'application/zip';
      default: return null;
    }
  }

  Future<void> sendAttachment() async {
    if (sending) {
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
      if (result == null || result.files.isEmpty) {
        return;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      final mime = _mimeFor(file.extension ?? '');
      if (bytes == null || mime == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('نوع الملف غير مدعوم. اختر صورة أو فيديو أو صوتاً أو PDF أو TXT أو ZIP.')),
          );
        }
        return;
      }
      if (bytes.length > 50 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الحد الأقصى لحجم الملف هو 50 ميغابايت.')),
          );
        }
        return;
      }
      setState(() => sending = true);
      final uid = client.auth.currentUser!.id;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path = '${widget.conversationId}/$uid/${DateTime.now().microsecondsSinceEpoch}_$safeName';
      await client.storage.from('helba-chat-media').uploadBinary(
        path, bytes, fileOptions: FileOptions(contentType: mime, upsert: false),
      );
      final type = mime.startsWith('image/') ? 'image'
          : mime.startsWith('video/') ? 'video'
          : mime.startsWith('audio/') ? 'audio' : 'file';
      await client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': uid,
        'body': file.name,
        'message_type': type,
        'attachment_path': path,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر رفع الملف. تحقق من الاتصال ونوع الملف.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => sending = false);
      }
    }
  }

  Future<void> openAttachment(String path) async {
    try {
      final url = await client.storage.from('helba-chat-media').createSignedUrl(path, 300);
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
    if (body.isEmpty || sending) return;
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
        'sender_id': client.auth.currentUser!.id,
        'body': body,
        'message_type': 'text',
      });
      input.clear();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الرسالة.')));
    } finally { if (mounted) setState(() => sending = false); }
  }

  @override
  void dispose() { input.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final stream = client.from('messages').stream(primaryKey: ['id'])
      .eq('conversation_id', widget.conversationId).order('created_at');
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snap) {
            if (snap.hasError) return const Center(child: Text('تعذر تحميل الرسائل'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('ابدأ المحادثة برسالة ترحيب 👋'));
            return ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                final mine = row['sender_id'] == client.auth.currentUser!.id;
                final time = DateTime.tryParse(row['created_at']?.toString() ?? '');
                return Align(
                  alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: mine ? const Color(0xFFDDF3E6) : Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (row['attachment_path'] != null)
                        InkWell(
                          onTap: () => openAttachment(row['attachment_path'].toString()),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.attach_file, size: 18, color: green),
                            const SizedBox(width: 5),
                            Flexible(child: Text(row['body']?.toString() ?? 'مرفق', style: const TextStyle(decoration: TextDecoration.underline))),
                            const SizedBox(width: 5),
                            const Icon(Icons.download_rounded, size: 17, color: green),
                          ]),
                        )
                      else
                        Text(row['body']?.toString() ?? ''),
                      if (time != null) Text(DateFormat('HH:mm').format(time), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                    ]),
                  ),
                );
              },
            );
          },
        )),
        SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(children: [
            IconButton(
              tooltip: 'إرفاق ملف',
              onPressed: sending ? null : sendAttachment,
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4, decoration: InputDecoration(hintText: 'اكتب رسالة...', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none)))),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: sending ? null : send, icon: const Icon(Icons.send), style: IconButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white)),
          ]),
        )),
      ]),
    );
  }
}
