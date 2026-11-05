import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'config.dart';

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested in test/widget_test.dart).
// ---------------------------------------------------------------------------

/// True when the story's expiry moment has been reached. A story is readable
/// while expires_at is strictly in the future (matching the RLS policy
/// `expires_at > now()`), so a story exactly at its expiry is expired.
bool isStoryExpired(Map<String, dynamic> storyRow, DateTime now) {
  final expires =
      DateTime.tryParse(storyRow['expires_at']?.toString() ?? '');
  if (expires == null) return true;
  return !expires.isAfter(now);
}

/// Keeps only the rows whose expiry is still in the future.
List<Map<String, dynamic>> filterUnexpiredStories(
    List<Map<String, dynamic>> rows, DateTime now) {
  return rows.where((row) => !isStoryExpired(row, now)).toList();
}

/// 'image' / 'video' for a media mime type, or null for anything else
/// (for example application/pdf is not a story medium).
String? storyMediaTypeFromMime(String? mime) {
  if (mime == null) return null;
  final lower = mime.toLowerCase();
  if (lower.startsWith('image/')) return 'image';
  if (lower.startsWith('video/')) return 'video';
  return null;
}

/// Mime type for a story file extension, or null when unsupported.
String? storyMimeForExtension(String extension) {
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
    default:
      return null;
  }
}

/// Groups story rows by author id, preserving first-seen author order and
/// the row order inside each group.
Map<String, List<Map<String, dynamic>>> groupStoriesByUser(
    List<Map<String, dynamic>> rows) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final userId = row['user_id']?.toString() ?? '';
    groups.putIfAbsent(userId, () => []).add(row);
  }
  return groups;
}

/// Display name for a story author: the embedded profile's display_name,
/// falling back to @username, then to a generic label.
String storyAuthorName(Map<String, dynamic> storyRow) {
  final profile = storyRow['profiles'] as Map<String, dynamic>?;
  final display = profile?['display_name']?.toString().trim() ?? '';
  if (display.isNotEmpty) return display;
  final username = profile?['username']?.toString() ?? '';
  if (username.isNotEmpty) return '@$username';
  return 'مستخدم هلبة';
}

// ---------------------------------------------------------------------------
// Loading.
// ---------------------------------------------------------------------------

/// Loads unexpired stories (newest first) with the author's profile.
Future<List<Map<String, dynamic>>> loadStories() async {
  final rows = await Supabase.instance.client
      .from('stories')
      .select(
          'id,user_id,media_url,media_type,created_at,expires_at,profiles(display_name,username)')
      .gt('expires_at', DateTime.now().toIso8601String())
      .order('created_at', ascending: false);
  final stories = rows.cast<Map<String, dynamic>>();
  // The query already filters by expiry, but re-filter client-side so a
  // story that expired between query and render never shows.
  return filterUnexpiredStories(stories, DateTime.now());
}

// ---------------------------------------------------------------------------
// Story rings row (top of the inbox).
// ---------------------------------------------------------------------------

class StoryRingsRow extends StatefulWidget {
  /// Incremented by the inbox on pull-to-refresh to reload the stories.
  final ValueNotifier<int> refreshTick;

  const StoryRingsRow({super.key, required this.refreshTick});

  @override
  State<StoryRingsRow> createState() => StoryRingsRowState();
}

class StoryRingsRowState extends State<StoryRingsRow> {
  late Future<List<Map<String, dynamic>>> _storiesFuture;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _storiesFuture = loadStories();
    widget.refreshTick.addListener(_reload);
  }

  @override
  void dispose() {
    widget.refreshTick.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _storiesFuture = loadStories());
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _uploadStory() async {
    if (_uploading) return;
    String? uploadedPath;
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'mov'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final mime = storyMimeForExtension(file.extension ?? '');
      if (mime == null) {
        _showMessage('نوع الملف غير مدعوم. اختر صورة أو فيديو.');
        return;
      }
      const maxBytes = 50 * 1024 * 1024;
      if (file.size <= 0 || file.size > maxBytes) {
        _showMessage(
            'يجب أن يكون حجم الملف أكبر من صفر ولا يتجاوز 50 ميغابايت.');
        return;
      }
      final filePath = file.path;
      if (filePath == null) {
        _showMessage('تعذر الوصول إلى الملف المحدد.');
        return;
      }
      if (!mounted) return;
      setState(() => _uploading = true);
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser!.id;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path =
          '$uid/${DateTime.now().microsecondsSinceEpoch}_$safeName';
      await client.storage.from('helba-stories').upload(
            path,
            io.File(filePath),
            fileOptions: FileOptions(contentType: mime, upsert: false),
          );
      uploadedPath = path;
      await client.from('stories').insert({
        'user_id': uid,
        'media_url': path,
        'media_type': storyMediaTypeFromMime(mime),
        'expires_at':
            DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      });
      uploadedPath = null;
      _showMessage('تم نشر الحالة.');
      _reload();
    } catch (_) {
      if (uploadedPath != null) {
        try {
          await Supabase.instance.client.storage
              .from('helba-stories')
              .remove([uploadedPath]);
        } catch (_) {
          // Keep the original upload error; an orphan can be cleaned up later.
        }
      }
      _showMessage('تعذر نشر الحالة. تحقق من الاتصال ونوع الملف.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _storiesFuture,
        builder: (context, snap) {
          final stories = snap.data ?? const <Map<String, dynamic>>[];
          final groups = groupStoriesByUser(stories);
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _RingTile(
                label: 'أضف حالة',
                onTap: _uploading ? null : _uploadStory,
                child: Stack(
                  alignment: Alignment.bottomLeft,
                  children: [
                    const CircleAvatar(
                      radius: 30,
                      backgroundColor: Color(0xFFE1F1E8),
                      child: Icon(Icons.person, size: 32, color: green),
                    ),
                    if (_uploading)
                      const SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    else
                      Container(
                        decoration: const BoxDecoration(
                          color: green,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: const Icon(Icons.add,
                            size: 18, color: Colors.white),
                      ),
                  ],
                ),
              ),
              for (final entry in groups.entries)
                _RingTile(
                  label: storyAuthorName(entry.value.first),
                  onTap: () {
                    // View oldest first, like WhatsApp status.
                    final ordered = List<Map<String, dynamic>>.from(
                        entry.value.reversed);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StoryViewerPage(
                          authorId: entry.key,
                          authorName: storyAuthorName(entry.value.first),
                          stories: ordered,
                        ),
                      ),
                    ).then((changed) {
                      if (changed == true) _reload();
                    });
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: green, width: 3),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: CircleAvatar(
                      radius: 27,
                      backgroundColor: const Color(0xFFE1F1E8),
                      child: Text(
                        storyAuthorName(entry.value.first).characters.first,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: green),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RingTile extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Widget child;

  const _RingTile(
      {required this.label, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              child,
              const SizedBox(height: 4),
              SizedBox(
                width: 64,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Story viewer.
// ---------------------------------------------------------------------------

class StoryViewerPage extends StatefulWidget {
  final String authorId;
  final String authorName;
  final List<Map<String, dynamic>> stories;

  const StoryViewerPage({
    super.key,
    required this.authorId,
    required this.authorName,
    required this.stories,
  });

  @override
  State<StoryViewerPage> createState() => _StoryViewerPageState();
}

class _StoryViewerPageState extends State<StoryViewerPage>
    with SingleTickerProviderStateMixin {
  static const _imageDuration = Duration(seconds: 5);

  late List<Map<String, dynamic>> _stories;
  int _index = 0;
  late final AnimationController _progress;
  VideoPlayerController? _video;
  String? _signedUrl;
  bool _loadingMedia = true;
  bool _muted = false;
  bool _deleting = false;
  int _loadGeneration = 0;

  bool get _isMine =>
      Supabase.instance.client.auth.currentUser?.id == widget.authorId;

  @override
  void initState() {
    super.initState();
    _stories = List.of(widget.stories);
    _progress = AnimationController(vsync: this, duration: _imageDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _next();
      });
    _loadCurrent();
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    final generation = ++_loadGeneration;
    _progress.stop();
    _progress.reset();
    await _video?.dispose();
    _video = null;
    if (!mounted) return;
    setState(() {
      _loadingMedia = true;
      _signedUrl = null;
    });
    final story = _stories[_index];
    try {
      final url = await Supabase.instance.client.storage
          .from('helba-stories')
          .createSignedUrl(story['media_url'].toString(), 3600);
      if (!mounted || generation != _loadGeneration) return;
      if (story['media_type'] == 'video') {
        final controller = VideoPlayerController.networkUrl(Uri.parse(url));
        _video = controller;
        await controller.initialize();
        if (!mounted || generation != _loadGeneration) {
          await controller.dispose();
          return;
        }
        await controller.setVolume(_muted ? 0 : 1);
        final duration = controller.value.duration;
        _progress.duration =
            duration > Duration.zero ? duration : const Duration(seconds: 10);
        setState(() {
          _signedUrl = url;
          _loadingMedia = false;
        });
        await controller.play();
        _progress.forward();
      } else {
        _progress.duration = _imageDuration;
        setState(() {
          _signedUrl = url;
          _loadingMedia = false;
        });
        _progress.forward();
      }
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadingMedia = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تحميل الحالة.')),
      );
      _next();
    }
  }

  void _next() {
    if (_index < _stories.length - 1) {
      setState(() => _index++);
      _loadCurrent();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index--);
      _loadCurrent();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _toggleMute() async {
    final video = _video;
    if (video == null) return;
    setState(() => _muted = !_muted);
    await video.setVolume(_muted ? 0 : 1);
  }

  Future<void> _togglePlayPause() async {
    final video = _video;
    if (video == null) return;
    if (video.value.isPlaying) {
      _progress.stop();
      await video.pause();
    } else {
      await video.play();
      _progress.forward();
    }
    if (mounted) setState(() {});
  }

  Future<void> _deleteCurrent() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final story = _stories[_index];
    try {
      final client = Supabase.instance.client;
      await client.from('stories').delete().eq('id', story['id'].toString());
      await client.storage
          .from('helba-stories')
          .remove([story['media_url'].toString()]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف الحالة.')),
      );
      _stories.removeAt(_index);
      if (_stories.isEmpty) {
        Navigator.pop(context, true);
        return;
      }
      if (_index >= _stories.length) _index = _stories.length - 1;
      setState(() {});
      _loadCurrent();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر حذف الحالة.')),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = _stories[_index];
    final isVideo = story['media_type'] == 'video';
    final video = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Media.
            if (_loadingMedia)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white))
            else if (isVideo && video != null && video.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: video.value.aspectRatio,
                  child: VideoPlayer(video),
                ),
              )
            else if (!isVideo && _signedUrl != null)
              Center(
                child: Image.network(_signedUrl!, fit: BoxFit.contain),
              )
            else
              const Center(
                child: Text('تعذر عرض الحالة.',
                    style: TextStyle(color: Colors.white)),
              ),
            // Tap zones: the app is RTL, so "forward" (next story) is the
            // LEFT half of the screen and "back" (previous story) is the
            // RIGHT half. The zones are explicit Positioned halves so the
            // direction never depends on Row/Directionality ordering.
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: MediaQuery.of(context).size.width / 2,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _next,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: MediaQuery.of(context).size.width / 2,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _previous,
                child: const SizedBox.expand(),
              ),
            ),
            // Top bar: progress segments, author, controls (above tap zones).
            Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    children: [
                      for (var i = 0; i < _stories.length; i++)
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 2),
                            child: _ProgressSegment(
                              progress: _progress,
                              state: i < _index
                                  ? _SegmentState.done
                                  : i == _index
                                      ? _SegmentState.current
                                      : _SegmentState.pending,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: green,
                        child: Text(
                          widget.authorName.characters.first,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.authorName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16),
                        ),
                      ),
                      if (isVideo && video != null)
                        IconButton(
                          tooltip: _muted ? 'تشغيل الصوت' : 'كتم الصوت',
                          onPressed: _toggleMute,
                          icon: Icon(
                            _muted
                                ? Icons.volume_off
                                : Icons.volume_up,
                            color: Colors.white,
                          ),
                        ),
                      if (isVideo && video != null)
                        IconButton(
                          tooltip: video.value.isPlaying
                              ? 'إيقاف مؤقت'
                              : 'تشغيل',
                          onPressed: _togglePlayPause,
                          icon: Icon(
                            video.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                          ),
                        ),
                      if (_isMine)
                        IconButton(
                          tooltip: 'حذف الحالة',
                          onPressed: _deleting ? null : _deleteCurrent,
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.white),
                        ),
                      IconButton(
                        tooltip: 'إغلاق',
                        onPressed: () => Navigator.pop(context),
                        icon:
                            const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _SegmentState { done, current, pending }

class _ProgressSegment extends StatelessWidget {
  final AnimationController progress;
  final _SegmentState state;

  const _ProgressSegment({required this.progress, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state == _SegmentState.done) {
      return Container(
        height: 3,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    if (state == _SegmentState.pending) {
      return Container(
        height: 3,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) => LinearProgressIndicator(
        value: progress.value,
        minHeight: 3,
        backgroundColor: Colors.white.withValues(alpha: 0.35),
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
