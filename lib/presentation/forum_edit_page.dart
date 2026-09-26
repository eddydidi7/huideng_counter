import 'jieyuan_fields.dart';
import '../domain/content_limits.dart';
import 'dart:async';
import 'dart:io';
import '../domain/post_display.dart';
import '../data/local/forum_draft_store.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../data/repositories/forum_edits.dart';
import '../services/chat_image.dart';
import '../services/cloud_storage_provider.dart';
import 'note_rich_content.dart';
import 'shared_rich_editor.dart';

/// Attachments in display order (server order is sort_order, created_at, id).
List<Map<String, dynamic>> forumAttachmentsOf(Map<String, dynamic> post) {
  final list = [
    for (final raw in post['attachments'] as List? ?? [])
      Map<String, dynamic>.from(raw as Map),
  ];
  final index = {for (var i = 0; i < list.length; i++) list[i]['id']: i};
  list.sort((a, b) {
    final order = ((a['sort_order'] as num?) ?? 0).compareTo(
      (b['sort_order'] as num?) ?? 0,
    );
    return order != 0 ? order : index[a['id']]!.compareTo(index[b['id']]!);
  });
  return list;
}

/// Legacy image_urls only; ForumRemote.media() appends signed attachment URLs.
List<String> forumLegacyImagesOf(Map<String, dynamic> post) {
  final signed = {
    for (final a in post['attachments'] as List? ?? [])
      if (a is Map && a['url'] != null) a['url'],
  };
  return [
    for (final url in post['image_urls'] as List? ?? [])
      if (url is String && !signed.contains(url)) url,
  ];
}

/// Attachment payload for forum_author_write_v2: images in the edited order,
/// then non-image files in their original order.
List<Map<String, dynamic>> forumEditPayload(
  List<Map<String, dynamic>> images,
  List<Map<String, dynamic>> files,
) => [
  for (final item in [...images, ...files])
    {
      'id': item['id'],
      'path': item['path'],
      'name': (item['name'] as String? ?? 'image.jpg').substring(
        0,
        (item['name'] as String? ?? 'image.jpg').length.clamp(1, 200),
      ),
      'kind': item['kind'],
    },
];

class _MediaEditingUnavailable implements Exception {}

class ForumEditPage extends StatefulWidget {
  const ForumEditPage({super.key, required this.post, required this.edits});
  final Map<String, dynamic> post;
  final ForumEdits edits;
  @override
  State<ForumEditPage> createState() => _ForumEditPageState();
}

class _ForumEditPageState extends State<ForumEditPage>
    with WidgetsBindingObserver {
  late final title = TextEditingController(
    text: widget.post['title'] as String? ?? '',
  );
  late final body = TextEditingController(
    text: widget.post['body'] as String? ?? '',
  );
  late final rich = quill.QuillController(
    document: NoteRichContent.documentFromBody(
      widget.post['rich_body'] is List
          ? jsonEncode(widget.post['rich_body'])
          : body.text,
    ),
    selection: const TextSelection.collapsed(offset: 0),
  );
  bool get article =>
      widget.post['post_kind'] == 'article' || widget.post['rich_body'] is List;
  // Media edits stay in memory until save: cancelling leaves the post and
  // Storage untouched, and nothing is uploaded for an abandoned edit.
  late final List<Map<String, dynamic>> images = [
    for (final a in forumAttachmentsOf(widget.post))
      if (a['kind'] == 'image') a,
  ];
  late final List<Map<String, dynamic>> files = [
    for (final a in forumAttachmentsOf(widget.post))
      if (a['kind'] != 'image') a,
  ];
  late final List<String> legacy = forumLegacyImagesOf(widget.post);
  late final int legacyOriginal = legacy.length;
  bool mediaChanged = false;
  bool busy = false, changed = false, leaving = false;
  String? error;
  ForumDraftStore? draftStore;
  Timer? timer;
  bool loaded = false;
  bool draftConflict = false;
  dynamic draftRevision;
  Future<void> writes = Future.value();
  String get draftKey => 'edit:${widget.post['id']}';
  Future<void> loadDraft() async {
    try {
      draftStore = await ForumDraftStore.open(widget.edits.userId);
      final d = await draftStore!.read(draftKey);
      if (!mounted) return;
      draftRevision = widget.post['content_revision'];
      if (d != null && d['saved'] != true) {
        draftRevision = d['revision'];
        if (d['revision'] != widget.post['content_revision']) {
          draftConflict = true;
          setState(() => error = '云端文章已更新。旧草稿已保留；请复制后与云端内容核对，再明确确认使用当前内容。');
        }
        title.text = d['title'] as String? ?? title.text;
        if (d['jieyuan'] is Map) {
          jieyuan = Map<String, dynamic>.from(d['jieyuan']);
        }
        body.text = d['body'] as String? ?? body.text;
        if (d['rich'] is List) {
          rich.document = quill.Document.fromJson(d['rich']);
        }
        changed = true;
      }
      setState(() => loaded = true);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取编辑草稿，请返回后重试。');
    }
  }

  late Map<String, dynamic> jieyuan = Map<String, dynamic>.from(
    widget.post['jieyuan'] as Map? ?? newJieyuan(),
  );
  Future<void> persist({bool saved = false}) {
    if (!loaded || draftStore == null || (!changed && !saved)) {
      return Future.value();
    }
    final value = {
      'title': title.text,
      'body': body.text,
      'rich': rich.document.toDelta().toJson(),
      'revision': draftRevision,
      'jieyuan': jieyuan,
      'saved': saved,
    };
    writes = writes
        .catchError((Object _) {})
        .then((_) => draftStore!.write(draftKey, value));
    return writes;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) persist().catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadDraft();
    title.addListener(markChanged);
    body.addListener(markChanged);
    rich.addListener(markChanged);
  }

  void markChanged() {
    if (!loaded) return;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 250), () {
      persist().catchError((Object _) {
        if (mounted) setState(() => error = '编辑草稿保存失败，请重试。');
      });
    });
    if (!changed && mounted) setState(() => changed = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    if (changed) persist().catchError((Object _) {});
    title.dispose();
    body.dispose();
    rich.dispose();
    super.dispose();
  }

  void mediaEdited(VoidCallback change) {
    setState(() {
      change();
      mediaChanged = true;
    });
    markChanged();
  }

  Future<void> addImages({bool camera = false}) async {
    if (busy || !loaded) return;
    try {
      final picked = <(String, String)>[];
      if (camera) {
        final shot = await ImagePicker().pickImage(source: ImageSource.camera);
        if (shot != null) picked.add((shot.path, shot.name));
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          withData: false,
          allowMultiple: true,
        );
        for (final f in result?.files ?? <PlatformFile>[]) {
          if (f.path != null) picked.add((f.path!, f.name));
        }
      }
      var skipped = 0;
      final added = <Map<String, dynamic>>[];
      for (final (path, name) in picked) {
        final size = await File(path).length();
        if (size < 1 ||
            size > 10 * 1024 * 1024 ||
            images.length + files.length + added.length >= 512) {
          skipped++;
          continue;
        }
        added.add({
          'id': const Uuid().v4(),
          'source': path,
          'name': name,
          'kind': 'image',
          'new': true,
        });
      }
      if (added.isNotEmpty) mediaEdited(() => images.addAll(added));
      if (skipped > 0 && mounted) {
        setState(() => error = '有 $skipped 张图片未添加：单张不超过10MB，附件最多512个。');
      }
    } catch (_) {
      if (mounted) setState(() => error = '图片未能添加，请重试。');
    }
  }

  Future<void> photoMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择（多图）'),
              onTap: () => Navigator.pop(ctx, 'album'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (choice != null) await addImages(camera: choice == 'camera');
  }

  Future<void> clearImages() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全部图片？'),
        content: const Text('保存后帖子只保留文字。点保存之前，原帖子不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      mediaEdited(() {
        images.clear();
        legacy.clear();
      });
    }
  }

  /// Step 1 of a media save: upload only the newly added images. Returns the
  /// uploaded paths so a failed save can remove them again.
  Future<List<String>> uploadNewImages() async {
    final client = widget.edits.client;
    final owner = widget.edits.userId;
    final uploaded = <String>[];
    for (final image in images.where((i) => i['new'] == true)) {
      final path = '$owner/${widget.post['id']}/${image['id']}';
      if (image['uploaded_path'] != path) {
        final bytes = await File(image['source'] as String).readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) throw StateError('file_size');
        final data = await compute(compressChatImage, bytes);
        try {
          await SupabaseStorageProvider(client).uploadBytes(
            'forum-files',
            path,
            data,
            contentType: 'image/jpeg',
          );
        } on StorageException catch (e) {
          // A lost upload response may leave this immutable UUID object present.
          if (e.statusCode != '409' && e.statusCode != '400') rethrow;
          final found = await client.storage
              .from('forum-files')
              .list(
                path: '$owner/${widget.post['id']}',
                searchOptions: SearchOptions(search: image['id'] as String),
              );
          if (!found.any((o) => o.name == image['id'])) rethrow;
        }
        if (widget.edits.userId != owner) {
          throw const AuthException('login_required');
        }
        image['uploaded_path'] = path;
      }
      image['path'] = path;
      uploaded.add(path);
    }
    return uploaded;
  }

  Future<void> save(bool cloud) async {
    if (!loaded || busy || draftConflict) return;
    final text = article
        ? rich.document.toPlainText().trimRight()
        : body.text.trim();
    final heading = title.text.trim();
    final hasMedia =
        images.isNotEmpty || legacy.isNotEmpty || files.isNotEmpty;
    if (heading.runes.length > 160 ||
        (text.trim().isEmpty && !hasMedia) ||
        !isArticleContentWithinLimit(text)) {
      setState(
        () => error = '标题最多160字，正文最多500万字符；正文和图片不能同时为空。',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    var uploaded = <String>[];
    var queued = false;
    try {
      if (mediaChanged) {
        if (!await widget.edits.mediaEditingAvailable()) {
          throw _MediaEditingUnavailable();
        }
        uploaded = await uploadNewImages();
      }
      await widget.edits.save(
        widget.post,
        'edit',
        title: heading,
        body: text,
        jieyuan: widget.post['jieyuan'] is Map ? jieyuan : null,
        richBody: article ? rich.document.toDelta().toJson() : null,
        attachments: mediaChanged ? forumEditPayload(images, files) : null,
        imageUrls: mediaChanged && legacy.length != legacyOriginal
            ? List.of(legacy)
            : null,
        uploadedPaths: uploaded,
      );
      queued = true;
      timer?.cancel();
      await persist(saved: true);
      changed = false;
      if (cloud) await widget.edits.sync();
      final pending = await widget.edits.pending();
      if (!mounted) return;
      final waiting = pending.any((p) => p['post_id'] == widget.post['id']);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(waiting ? '已保存到本机，可在个人 → 待同步修改中查看和重试。' : '已更新原文章并同步云端'),
        ),
      );
      setState(() {
        changed = false;
        leaving = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } catch (e) {
      // Nothing was queued: the post is unchanged, so new uploads are orphans.
      if (!queued && uploaded.isNotEmpty) {
        await widget.edits.removeFiles(uploaded);
        for (final image in images) {
          image.remove('uploaded_path');
        }
      }
      if (mounted) {
        setState(
          () => error = e is _MediaEditingUnavailable
              ? '服务器尚未开通帖子图片编辑（需部署 202609250070 迁移），本次没有做任何修改。'
              : queued
              ? '已保存在本机，稍后可在个人 → 待同步修改中重试。'
              : mediaChanged
              ? '保存未完成，帖子保持原样。新图片需要联网上传，请检查网络和登录后重试。'
              : '保存未完成。请确认登录账号，并先处理此文章已有的待同步修改。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget thumbnail(
    Map<String, dynamic>? image,
    String? url,
    VoidCallback onRemove, {
    int? number,
  }) {
    final broken = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.broken_image_outlined),
    );
    final Widget picture = image?['new'] == true
        ? Image.file(
            File(image!['source'] as String),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => broken,
          )
        : (url ?? image?['url']) is String
        ? Image.network(
            (url ?? image!['url']) as String,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => broken,
          )
        : broken;
    return SizedBox(
      width: 92,
      height: 92,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: picture,
            ),
          ),
          if (number != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                color: Colors.black54,
                child: Text(
                  '$number',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: '删除这张图片',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
              onPressed: busy ? null : onRemove,
              icon: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget imageEditor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            '图片（${images.length + legacy.length}）',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('forum-edit-add-images'),
            onPressed: busy || !loaded ? null : photoMenu,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('添加图片'),
          ),
          if (images.isNotEmpty || legacy.isNotEmpty)
            TextButton(
              key: const ValueKey('forum-edit-clear-images'),
              onPressed: busy || !loaded ? null : clearImages,
              child: const Text('全部删除'),
            ),
        ],
      ),
      if (legacy.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final url in List.of(legacy))
              thumbnail(null, url, () => mediaEdited(() => legacy.remove(url))),
          ],
        ),
      if (legacy.isNotEmpty && images.isNotEmpty) const SizedBox(height: 8),
      if (images.isNotEmpty)
        SizedBox(
          height: 96,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: images.length,
            onReorderItem: (from, to) {
              if (busy) return;
              mediaEdited(() => images.insert(to, images.removeAt(from)));
            },
            itemBuilder: (_, i) => Padding(
              key: ValueKey('forum-edit-image-${images[i]['id']}'),
              padding: const EdgeInsets.only(right: 8),
              child: thumbnail(
                images[i],
                null,
                () => mediaEdited(() => images.removeAt(i)),
                number: legacy.length + i + 1,
              ),
            ),
          ),
        ),
      if (images.length > 1)
        Text('长按图片拖动可调整顺序', style: Theme.of(context).textTheme.bodySmall),
      if (images.isEmpty && legacy.isEmpty)
        Text('没有图片，保存后为纯文字帖子', style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving || (!changed && !busy),
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || busy) return;
      try {
        timer?.cancel();
        await persist();
        if (!mounted) return;
        setState(() => leaving = true);
        await WidgetsBinding.instance.endOfFrame;
        if (context.mounted) Navigator.pop(context);
      } catch (_) {
        if (mounted) setState(() => error = '草稿保存失败，请重试。');
      }
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('编辑原文章')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (draftConflict)
            Wrap(
              children: [
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(
                      text:
                          '${title.text}\n${article ? rich.document.toPlainText() : body.text}',
                    ),
                  ),
                  child: const Text('复制草稿'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      draftConflict = false;
                      draftRevision = widget.post['content_revision'];
                      error = null;
                    });
                  },
                  child: const Text('已核对，使用当前内容'),
                ),
              ],
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (widget.post['jieyuan'] is Map)
            JieyuanFields(
              enabled: !busy && !draftConflict && loaded,
              value: jieyuan,
              editing: true,
              onChanged: (v) {
                setState(() => jieyuan = v);
                markChanged();
              },
            ),
          TextField(
            controller: title,
            enabled: !busy && loaded,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          const SizedBox(height: 12),
          if (article) ...[
            quill.QuillSimpleToolbar(controller: rich),
            SizedBox(
              height: 360,
              child: AbsorbPointer(
                absorbing: busy || !loaded,
                child: SharedRichEditor(
                  controller: rich,
                  config: const quill.QuillEditorConfig(
                    padding: EdgeInsets.all(12),
                  ),
                ),
              ),
            ),
          ] else
            TextField(
              controller: body,
              enabled: !busy && loaded,
              minLines: 10,
              maxLines: null,
              decoration: const InputDecoration(labelText: '正文'),
            ),
          const SizedBox(height: 16),
          imageEditor(),
          const SizedBox(height: 12),
          const Text('可删除、添加、拖动调整图片；评论、点赞、收藏保留。点保存之前原帖子不会改变。'),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => save(false),
                child: const Text('保存本地待同步'),
              ),
              FilledButton(
                onPressed: busy ? null : () => save(true),
                child: const Text('保存并同步'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class ForumPendingPage extends StatefulWidget {
  const ForumPendingPage({super.key, required this.edits});
  final ForumEdits edits;
  @override
  State<ForumPendingPage> createState() => _ForumPendingPageState();
}

class _ForumPendingPageState extends State<ForumPendingPage> {
  List<Map<String, dynamic>> rows = [];
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool sync = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (sync) await widget.edits.sync();
      final value = await widget.edits.pending();
      if (mounted) setState(() => rows = value);
    } catch (_) {
      if (mounted) {
        setState(() {
          rows = [];
          error = '请登录原账号后查看本地修改。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('待同步修改'),
      actions: [
        IconButton(
          onPressed: busy ? null : () => load(sync: true),
          icon: const Icon(Icons.sync),
          tooltip: '重试同步',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (!busy && rows.isEmpty && error == null) const Text('没有待同步修改'),
        for (final row in rows)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row['operation'] == 'delete' ? '删除' : '编辑'}：${getPostDisplayTitle(row['title'] != null ? row : (row['local_post'] as Map? ?? row))}',
                  ),
                  Text(
                    row['error'] == 'content_conflict'
                        ? '云端文章已被修改。请先复制本地正文，再放弃此请求，打开云端最新文章重新编辑。'
                        : row['error'] == null
                        ? '已保存在本机，等待同步。'
                        : '暂时无法同步，本地修改已保留，请稍后重试。',
                  ),
                  if (row['body'] != null)
                    SelectableText(row['body'] as String),
                  Wrap(
                    children: [
                      if (row['body'] != null)
                        TextButton(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                              text: '${row['title']}\n${row['body']}',
                            ),
                          ),
                          child: const Text('复制本地内容'),
                        ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () async {
                                final accepted = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('放弃本地待同步请求？'),
                                    content: const Text(
                                      '不会撤回可能已经同步到云端的操作。未同步的本地修改将被清除，请先复制保存正文。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('放弃请求'),
                                      ),
                                    ],
                                  ),
                                );
                                if (accepted == true) {
                                  try {
                                    await widget.edits.discard(
                                      row['post_id'] as String,
                                    );
                                    if (mounted) await load();
                                  } catch (_) {
                                    if (mounted) {
                                      setState(() => error = '操作未完成，请重试。');
                                    }
                                  }
                                }
                              },
                        child: const Text('放弃本地请求'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
