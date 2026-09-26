import 'adaptive_action_bar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import '../services/note_export.dart';
import 'forum_chat_share.dart';
import 'forum_compose_page.dart';
import 'forum_page.dart';
import '../data/repositories/forum_repository.dart';
import '../data/remote/forum_remote.dart';
import '../data/local/home_message_cache.dart';
import 'shared_rich_editor.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../domain/large_note.dart';
import 'note_reader_page.dart';

/// Existing Delta format, bounded editing document. No data is rewritten on open.
class LargeNoteEditor extends StatefulWidget {
  const LargeNoteEditor({
    super.key,
    required this.app,
    required this.repository,
    required this.note,
  });
  final AppController app;
  final NotesRepository repository;
  final Map<String, Object?> note;
  @override
  State<LargeNoteEditor> createState() => _LargeNoteEditorState();
}

class _LargeNoteEditorState extends State<LargeNoteEditor>
    with WidgetsBindingObserver {
  List<String> chunks = [];
  quill.QuillController? editor;
  StreamSubscription? changes;
  Timer? debounce;
  int page = 0, generation = 0, persisted = 0;
  bool synthetic = false, loading = true, exiting = false, rechunking = false;
  String? error;
  late Map<String, Object?> saved = {...widget.note};
  Future<void>? writing;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  Future<void> load() async {
    chunks = await compute(splitNoteForEditing, saved['body'] as String? ?? '');
    if (!mounted) return;
    select(0);
    setState(() => loading = false);
  }

  void select(int index) {
    changes?.cancel();
    editor?.dispose();
    page = index;
    final delta = (jsonDecode(chunks[page]) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    synthetic =
        delta.isEmpty ||
        delta.last['insert'] is! String ||
        !(delta.last['insert'] as String).endsWith('\n');
    if (synthetic) delta.add({'insert': '\n'});
    editor = quill.QuillController(
      document: quill.Document.fromJson(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    changes = editor!.document.changes.listen((_) {
      generation++;
      if (!rechunking && editor!.document.length > 32000) {
        rechunking = true;
        scheduleMicrotask(rechunk);
      }
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 1800), save);
    });
  }

  Future<void> rechunk() async {
    if (!mounted) return;
    setState(() {});
    debounce?.cancel();
    capture();
    final parts = await compute(splitNoteForEditing, chunks[page]);
    if (!mounted) return;
    chunks.replaceRange(page, page + 1, parts);
    select(page);
    setState(() => rechunking = false);
    await save();
  }

  void capture() {
    final delta = editor!.document
        .toDelta()
        .toJson()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (synthetic && delta.isNotEmpty && delta.last['insert'] is String) {
      final text = delta.last['insert'] as String;
      if (text.endsWith('\n')) {
        if (text.length == 1) {
          delta.removeLast();
        } else {
          delta.last['insert'] = text.substring(0, text.length - 1);
        }
      }
    }
    chunks[page] = jsonEncode(delta);
  }

  Future<void> save() async {
    debounce?.cancel();
    if (loading || rechunking || editor == null) return;
    if (writing != null) await writing;
    if (generation == persisted) return;
    capture();
    final current = generation;
    final snapshot = List<String>.from(chunks);
    final task = write(snapshot, current);
    writing = task;
    await task;
    writing = null;
  }

  Future<void> write(List<String> snapshot, int current) async {
    try {
      final body = await compute(joinNoteChunks, snapshot);
      saved = await widget.repository.save({...saved, 'body': body});
      persisted = current;
      error = null;
    } catch (_) {
      error = '保存失败或超过500万字符；编辑内容仍保留，请重试。';
    }
    if (mounted) setState(() {});
  }

  Future<void> move(int target) async {
    do {
      await save();
    } while (mounted &&
        !rechunking &&
        error == null &&
        generation != persisted);
    if (!mounted || error != null || rechunking) return;
    setState(() => select(target.clamp(0, chunks.length - 1)));
  }

  Future<void> leave() async {
    do {
      await save();
    } while (mounted &&
        !rechunking &&
        error == null &&
        generation != persisted);
    if (!mounted || error != null || rechunking) return;
    setState(() => exiting = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  Future<void> read() async {
    do {
      await save();
    } while (mounted &&
        !rechunking &&
        error == null &&
        generation != persisted);
    if (!mounted || error != null || rechunking) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteReaderPage(
          app: widget.app,
          body: saved['body'] as String,
          noteId: saved['id'] as String,
          scope: widget.app.scopeId,
          title: saved['title'] as String? ?? '',
        ),
      ),
    );
    final latest = await widget.repository.get(saved['id'] as String);
    if (!mounted) return;
    if (latest['body'] == saved['body']) {
      setState(() => saved = latest);
      if (latest['deletedAt'] != null) await leave();
    }
  }

  Future<void> action(String action) async {
    if (action == 'search') return search();
    await save();
    if (!mounted || error != null || rechunking) return;
    try {
      if (['pin', 'favorite', 'favorite2', 'archive'].contains(action)) {
        final field = {
          'pin': 'isPinned',
          'favorite': 'isFavorite',
          'favorite2': 'isFavorite2',
          'archive': 'isArchived',
        }[action]!;
        saved = await widget.repository.save({
          ...saved,
          field: saved[field] == 1 ? 0 : 1,
        });
        return;
      }
      if (action == 'redbook') {
        final client = widget.app.cloud?.client;
        if (client == null) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ForumComposePage(
              app: widget.app,
              repository: ForumRepository(
                ForumRemote(client),
                HomeMessageCache(cacheKey: 'forum_feed'),
              ),
              categories: forumCategories,
              initialTitle: saved['title'] as String? ?? '',
              initialBody: saved['body'] as String,
              sourceNoteId: saved['id'] as String?,
            ),
          ),
        );
        return;
      }
      if (action.startsWith('export_')) {
        final format = action.substring(7);
        final bytes = format == 'pdf'
            ? await NoteExport.pdf(
                await compute(largeNoteOps, saved['body'] as String),
              )
            : await compute(exportLargeNote, {
                'body': saved['body'],
                'format': format,
              });
        await FilePicker.platform.saveFile(
          dialogTitle: '导出笔记',
          fileName: '笔记_${DateTime.now().millisecondsSinceEpoch}.$format',
          type: FileType.custom,
          allowedExtensions: [format],
          bytes: bytes,
        );
        return;
      }
      final text = await compute(plainLargeNote, saved['body'] as String);
      if (!mounted) return;
      if (action == 'chat') {
        return await shareTextToChat(context, widget.app, text);
      }
      if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: text));
      } else {
        await const MethodChannel(
          'org.huideng.counter/notes',
        ).invokeMethod('shareText', text);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作未完成，笔记已保存在本地。')));
      }
    }
  }

  Future<void> search() async {
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('查找正文'),
        content: TextField(controller: input),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('查找'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value == null || value.isEmpty) return;
    capture();
    final matches = await compute(searchNoteChunks, {
      'chunks': chunks,
      'query': value,
    });
    if (!mounted) return;
    if (matches.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有找到')));
      return;
    }
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('找到 ${matches.length} 个段落块'),
        children: [
          for (final i in matches.take(100))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Text('第 ${i + 1} 块'),
            ),
        ],
      ),
    );
    if (target != null) await move(target);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(save());
  }

  @override
  void dispose() {
    debounce?.cancel();
    changes?.cancel();
    editor?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: exiting,
    onPopInvokedWithResult: (p, _) {
      if (!p) leave();
    },
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        title: AdaptiveActionBar(
          menuIndex: 1,
          actions: [
            BarAction('阅读模式', read, color: const Color(0xff90caf9)),
            // Completion is deliberately a normal text action, not an alert.
            BarAction('完成', leave),
          ],
          menu: PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_horiz,
              color: Color(0xff90caf9),
              size: 30,
            ),
            constraints: const BoxConstraints(minWidth: 140),
            onSelected: action,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'search', child: Text('查找正文')),
              const PopupMenuItem(value: 'redbook', child: Text('发布到红书')),
              const PopupMenuItem(value: 'chat', child: Text('分享到聊天')),
              const PopupMenuItem(value: 'share', child: Text('其他方式分享')),
              const PopupMenuItem(value: 'pin', child: Text('置顶 / 取消置顶')),
              const PopupMenuItem(value: 'favorite', child: Text('收藏 / 取消收藏')),
              const PopupMenuItem(value: 'archive', child: Text('归档 / 取消归档')),
              for (final f in ['txt', 'pdf', 'md'])
                PopupMenuItem(
                  value: 'export_$f',
                  child: Text('导出 ${f.toUpperCase()}'),
                ),
              const PopupMenuItem(value: 'copy', child: Text('复制纯文本')),
            ],
          ),
        ),
      ),
      body: loading || rechunking
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: page > 0 ? () => move(page - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        '第 ${page + 1} / ${chunks.length} 块 · 分段编辑',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      onPressed: page + 1 < chunks.length
                          ? () => move(page + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                Expanded(
                  child: SharedRichEditor(
                    readingScope: widget.app.scopeId,
                    key: ValueKey(page),
                    controller: editor!,
                    config: quill.QuillEditorConfig(
                      embedBuilders: [NoteImageBuilder()],
                      expands: true,
                      padding: EdgeInsets.all(12),
                    ),
                  ),
                ),
                quill.QuillSimpleToolbar(
                  controller: editor!,
                  config: const quill.QuillSimpleToolbarConfig(
                    multiRowsDisplay: false,
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Text(
                    error ?? (generation == persisted ? '已本地保存' : '正在保存'),
                  ),
                ),
              ],
            ),
    ),
  );
}

List<dynamic> largeNoteOps(String body) {
  try {
    final value = jsonDecode(body);
    if (value is List &&
        value.every((e) => e is Map && e.containsKey('insert'))) {
      return value;
    }
  } catch (_) {}
  return [
    {'insert': body},
  ];
}

String plainLargeNote(String body) => NoteExport.plain(largeNoteOps(body));
Uint8List exportLargeNote(Map<String, dynamic> request) => Uint8List.fromList(
  utf8.encode(
    request['format'] == 'md'
        ? NoteExport.markdown(largeNoteOps(request['body']))
        : plainLargeNote(request['body']),
  ),
);
