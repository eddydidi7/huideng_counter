import '../services/resource_upload_policy.dart';
import 'jieyuan_fields.dart';
import '../domain/content_limits.dart';
import 'dart:async';
import 'package:image_picker/image_picker.dart';
import '../data/local/forum_draft_store.dart';
import '../services/forum_card_layout.dart';
import 'forum_card_editor.dart';
import '../services/cloud_storage_provider.dart';
import 'dart:convert';
import 'note_rich_content.dart';
import 'shared_rich_editor.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import '../services/chat_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import '../data/local/chat_store.dart';

String forumFailure(AppController app, Object error) {
  final limit = resourceLimitMessage(error);
  if (limit != null) return limit;
  if (error is AuthException) {
    return app.text(
      '请重新登录后发布，正文仍保留。',
      'Sign in again to publish; your text is retained.',
    );
  }
  if (error.toString().contains('shared_nickname_unavailable')) {
    return app.text(
      '暂时无法读取共用昵称，请在聊天页确认昵称后重试。',
      'Cannot load your shared name. Check your name in Chat and retry.',
    );
  }
  if (forumServiceMissing(error)) {
    return app.text('论坛发布服务尚未配置，请稍后重试。', 'Publishing is not configured yet.');
  }
  if (error is PostgrestException) {
    switch (error.message) {
      case 'jieyuan_disabled':
        return '当前等级或后台设置暂不允许此类结缘。';
      case 'jieyuan_daily_limit':
        return '已达到今日结缘发布额度，草稿已保留。';
      case 'jieyuan_image_limit':
        return '当前等级或资源开关限制了图片上传，请减少图片或使用纯文字。';
      case 'invalid_jieyuan':
      case 'invalid_price':
      case 'invalid_currency':
        return '请核对物品数量、价格和币种，草稿已保留。';

      case 'login_required':
        return app.text(
          '请先在“计数 → 设置 → 账号与同步”登录。',
          'Sign in under Counter → Settings → Account and sync.',
        );
      case 'rate_limited':
        return app.text(
          '操作太频繁，请稍等再试。发帖间隔30秒，回复间隔10秒。',
          'Please wait: 30 seconds between posts, 10 seconds between replies.',
        );
      case 'replies_closed':
        return app.text('此帖已锁定或关闭回复。', 'Replies are closed for this post.');
      case 'account_restricted':
        return app.text(
          '账号已被限制此操作。',
          'This action is restricted for your account.',
        );
      case 'post_unavailable':
        return app.text('帖子已隐藏或不可用。', 'This post is no longer available.');
      case 'request_conflict':
        return app.text(
          '提交编号冲突，请保留正文并重新打开编辑页。',
          'Request conflict. Keep your text and reopen the editor.',
        );
    }
  }
  return app.text(
    '操作未成功，请检查网络后重试；输入内容仍保留。',
    'Request failed. Check your connection and retry; your text is retained.',
  );
}

class ForumComposePage extends StatefulWidget {
  final Future<ForumDraftStore> Function(String)? openDraft;
  final AppController app;
  final ForumRepository repository;
  final String? postId;
  final String initialTitle, initialBody;
  final String? sourceNoteId;
  final String? shareSlug;
  final String initialCategory, initialKind;
  final Map<String, List<String>> categories;
  const ForumComposePage({
    super.key,
    this.openDraft,
    required this.app,
    required this.repository,
    required this.categories,
    this.postId,
    this.initialTitle = '',
    this.initialBody = '',
    this.sourceNoteId,
    this.shareSlug,
    this.initialCategory = 'feedback',
    this.initialKind = 'image_text',
  });
  @override
  State<ForumComposePage> createState() => _ForumComposePageState();
}

class _ForumComposePageState extends State<ForumComposePage>
    with WidgetsBindingObserver {
  final title = TextEditingController(),
      body = TextEditingController(),
      nickname = TextEditingController();
  final form = GlobalKey<FormState>();
  Map<String, dynamic> jieyuanConfig = {};
  Future<void> loadJieyuanConfig() async {
    try {
      final c = await widget.repository.remote?.client.rpc(
        'jieyuan_permissions',
      );
      if (c is Map && mounted) {
        setState(() => jieyuanConfig = Map<String, dynamic>.from(c));
      }
    } catch (_) {} // Existing local draft remains usable without a network.
  }

  Map<String, dynamic> jieyuan = newJieyuan();
  String postKind = 'image_text', accessLevel = 'public';
  String lastRichDelta = '';
  late final quill.QuillController rich;
  String category = 'feedback', requestId = const Uuid().v4();
  bool busy = false, finished = false, autoTextImage = false;
  String? error;
  final tags = TextEditingController();
  ForumDraftStore? draftStore;
  late final draftScope = app.scopeId;
  late final draftKey = 'v1:${widget.postId ?? widget.sourceNoteId ?? "new"}';
  bool ready = false, cardDirty = false;
  Map<String, dynamic>? card;
  Timer? draftTimer;
  Future<void> draftWrites = Future.value();
  Map<String, dynamic> snapshot() => {
    'title': title.text,
    'body': body.text,
    'rich': rich.document.toDelta().toJson(),
    'tags': tags.text,
    'category': category,
    'jieyuan': jieyuan,
    'kind': postKind,
    'access': accessLevel,
    'request': requestId,
    'auto': autoTextImage,
    'files': files.map((f) => Map<String, dynamic>.from(f)).toList(),
    'card': card,
    'card_dirty': cardDirty,
    'saved_at': DateTime.now().toUtc().toIso8601String(),
  };
  Future<void> loadDraft() async {
    try {
      draftStore = await (widget.openDraft ?? ForumDraftStore.open)(draftScope);
      final saved = await draftStore!.read(draftKey);
      if (!mounted) return;
      if (saved != null && saved['published'] != true) {
        title.text = saved['title'] as String? ?? '';
        body.text = saved['body'] as String? ?? '';
        tags.text = saved['tags'] as String? ?? '';
        category = saved['category'] as String? ?? category;
        if (saved['jieyuan'] is Map) {
          jieyuan = Map<String, dynamic>.from(saved['jieyuan']);
        }
        postKind = saved['kind'] as String? ?? postKind;
        accessLevel = saved['access'] as String? ?? accessLevel;
        requestId = saved['request'] as String? ?? requestId;
        autoTextImage = saved['auto'] == true;
        if (saved['rich'] is List) {
          rich.document = quill.Document.fromJson(saved['rich']);
        }
        files.clear();
        files.addAll(
          (saved['files'] as List? ?? []).map(
            (v) => Map<String, dynamic>.from(v),
          ),
        );
        if (saved['card'] is Map) {
          card = Map<String, dynamic>.from(saved['card']);
        }
        cardDirty = saved['card_dirty'] == true;
      }
      if (!widget.categories.containsKey(category)) {
        category = widget.initialCategory;
      }
      setState(() => ready = true);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本地草稿，请重试后继续，现有草稿未改动。');
    }
  }

  Future<void> saveDraft() {
    if (!ready || finished || draftStore == null) return Future.value();
    final value = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(snapshot())) as Map,
    );
    final next = draftWrites
        .catchError((Object _) {})
        .then((_) => draftStore!.write(draftKey, value));
    draftWrites = next;
    return next;
  }

  void scheduleDraft() {
    if (!ready) return;
    draftTimer?.cancel();
    draftTimer = Timer(const Duration(milliseconds: 250), () {
      saveDraft().catchError((Object _) {
        if (mounted) setState(() => error = '本地草稿保存失败，请检查剩余空间并重试。');
      });
    });
  }

  final files = <Map<String, dynamic>>[];
  AppController get app => widget.app;
  bool get reply => widget.postId != null;
  bool get hasIdentity =>
      widget.repository.remote?.client.auth.currentUser != null;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    category = widget.initialCategory;
    loadJieyuanConfig();
    title.text = widget.initialTitle;
    body.text = NoteRichContent.plainText(widget.initialBody);
    rich = quill.QuillController(
      document: NoteRichContent.documentFromBody(widget.initialBody),
      selection: const TextSelection.collapsed(offset: 0),
    );
    postKind = widget.sourceNoteId != null ? 'article' : widget.initialKind;
    lastRichDelta = jsonEncode(rich.document.toDelta().toJson());
    rich.addListener(() {
      final delta = jsonEncode(rich.document.toDelta().toJson());
      if (delta == lastRichDelta) return;
      lastRichDelta = delta;
      if (postKind == 'article') {
        body.text = rich.document.toPlainText().trimRight();
        changed('');
      }
    });
    title.addListener(scheduleDraft);
    body.addListener(scheduleDraft);
    tags.addListener(scheduleDraft);
    loadDraft();
    loadNickname();
  }

  Future<void> loadNickname() async {
    final remote = widget.repository.remote;
    final userId = remote?.client.auth.currentUser?.id;
    if (!hasIdentity || remote == null || userId == null) return;
    try {
      final store = await ChatStore.open(userId);
      final cached = await store.read('own_profile');
      if (!mounted || remote.client.auth.currentUser?.id != userId) return;
      if (cached.isNotEmpty) {
        nickname.text = cached.first['nickname'] as String? ?? '';
      }
    } catch (e) {
      debugPrint('Shared nickname cache: ${e.runtimeType}');
    }
    try {
      final name = await remote.sharedNickname();
      if (!mounted || remote.client.auth.currentUser?.id != userId) return;
      setState(() => nickname.text = name);
    } catch (e) {
      debugPrint('Shared nickname load: ${e.runtimeType}');
      // Publishing retries the authoritative account lookup; never publishes
      // under a made-up fallback name when the profile cannot be loaded.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      draftTimer?.cancel();
      saveDraft().catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (ready && !finished) saveDraft().catchError((Object _) {});
    draftTimer?.cancel();
    tags.dispose();
    rich.dispose();
    title.dispose();
    body.dispose();
    nickname.dispose();
    super.dispose();
  }

  void changed(String _) {
    if (!ready) return;
    requestId = const Uuid().v4();
    scheduleDraft();
  }

  Future<void> makeTextImage() async {
    final value =
        card ?? {'text': body.text, 'style': ForumCardStyle().toJson()};
    final style = ForumCardStyle.fromJson(
      Map<String, dynamic>.from(value['style']),
    );
    final pages = paginateForumCard(value['text'] as String, style);
    if (pages.length + files.where((f) => f['generated'] != true).length >
        512) {
      throw StateError('最多512张图片，请拆分发布');
    }
    final generated = <Map<String, dynamic>>[];
    for (var i = 0; i < pages.length; i++) {
      final bytes = await renderForumCardPage(pages[i], style, i, pages.length);
      final source = await draftStore!.image(bytes);
      generated.add({
        'id': const Uuid().v4(),
        'source': source,
        'kind': 'image',
        'name': '文字图片-${i + 1}.png',
        'generated': true,
      });
    }
    // Replace only after every page was successfully persisted.
    requestId = const Uuid().v4();
    files.removeWhere((f) => f['generated'] == true);
    files.insertAll(0, generated);
    card = value;
    cardDirty = false;
    await saveDraft();
  }

  Future<void> previewTextImage() async {
    if (busy || !ready) return;
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => ForumCardEditor(
          initial:
              card ?? {'text': body.text, 'style': ForumCardStyle().toJson()},
          onDraft: (value) async {
            if (jsonEncode(card) == jsonEncode(value)) {
              return;
            }
            card = value;
            cardDirty = true;
            changed('');
            await saveDraft();
          },
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      card = result;
      if (cardDirty || !files.any((f) => f['generated'] == true)) {
        await makeTextImage();
      }
      if (body.text.trim().isEmpty) {
        body.text = (result['text'] as String).replaceAll('\f', '\n');
      }
      await saveDraft();
    } catch (_) {
      if (mounted) setState(() => error = '图片生成失败，文字和样式已保留，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addPicked(String path, String name, bool image) async {
    if (files.length >= 512) throw StateError('最多512个附件');
    final file = File(path);
    final size = await file.length();
    if (size < 1 || size > 10 * 1024 * 1024) throw StateError('file_size');
    final source = await draftStore!.importFile(path);
    files.add({
      'id': const Uuid().v4(),
      'source': source,
      'name': name,
      'kind': image ? 'image' : 'file',
    });
    changed('');
    await saveDraft();
  }

  Future<void> pick(bool image, {bool camera = false}) async {
    if (busy || !ready) return;
    setState(() => busy = true);
    try {
      if (camera) {
        final shot = await ImagePicker().pickImage(source: ImageSource.camera);
        if (shot != null) await addPicked(shot.path, shot.name, true);
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: image ? FileType.image : FileType.any,
          withData: false,
          allowMultiple: true,
        );
        for (final f in result?.files ?? <PlatformFile>[]) {
          if (f.path != null) await addPicked(f.path!, f.name, image);
        }
      }
    } catch (_) {
      if (mounted) setState(() => error = '部分文件未能添加，已添加的照片和草稿保留；单个文件不超过10MB。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> photoMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择（多图）'),
              onTap: () {
                Navigator.pop(ctx);
                pick(true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                pick(true, camera: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> previewFile(Map<String, dynamic> file) async {
    if (file['kind'] != 'image') return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: Image.file(
                  File(file['source'] as String),
                  errorBuilder: (_, _, _) => const Text('本地图片不可用，请重新选择'),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> uploadFiles() async {
    final client = widget.repository.remote?.client;
    if (files.isEmpty) return [];
    if (client == null || client.auth.currentUser == null) {
      throw const AuthException('login_required');
    }
    final userId = client.auth.currentUser!.id;
    final payload = <Map<String, dynamic>>[];
    for (final file in files) {
      final path = '$userId/$requestId/${file['id']}';
      if (file['uploaded_path'] != path) {
        final bytes =
            file['bytes'] as Uint8List? ??
            await File(file['source'] as String).readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) throw StateError('file_size');
        final data = file['kind'] == 'image' && file['generated'] != true
            ? await compute(compressChatImage, bytes)
            : bytes;
        try {
          await SupabaseStorageProvider(client).uploadBytes(
            'forum-files',
            path,
            data,
            contentType: file['generated'] == true
                ? 'image/png'
                : file['kind'] == 'image'
                ? 'image/jpeg'
                : 'application/octet-stream',
          );
        } on StorageException catch (e) {
          // A lost upload response may leave this immutable UUID object present.
          if (e.statusCode != '409' && e.statusCode != '400') rethrow;
          final found = await client.storage
              .from('forum-files')
              .list(
                path: '$userId/$requestId',
                searchOptions: SearchOptions(search: file['id'] as String),
              );
          if (!found.any((o) => o.name == file['id'])) rethrow;
        }
        if (client.auth.currentUser?.id != userId) {
          throw const AuthException('login_required');
        }
        file['uploaded_path'] = path;
      }
      payload.add({
        'id': file['id'],
        'path': path,
        'name': (file['name'] as String).substring(
          0,
          (file['name'] as String).length.clamp(0, 200),
        ),
        'kind': file['kind'],
      });
    }
    return payload;
  }

  Future<void> submit() async {
    if (busy || !ready || !(form.currentState?.validate() ?? false)) return;
    if (!widget.repository.signedIn) {
      setState(
        () => error = app.text(
          '请先在“计数 → 设置 → 账号与同步”登录，之后再发布。',
          'Sign in under Counter → Settings → Account and sync before publishing.',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await saveDraft();
      if (app.scopeId != draftScope) {
        throw const AuthException('login_required');
      }
      final tagList = tags.text
          .split(RegExp(r'[,，\s]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (tagList.length > 10 || tagList.any((t) => t.length > 50)) {
        throw StateError('标签最多10个，每个不超过50字');
      }
      if (files.length > 512) throw StateError('最多512个附件，请分成多帖发布');
      final postBody = postKind == 'article'
          ? rich.document.toPlainText().trimRight()
          : body.text.trim();
      if ((postBody.isEmpty && (reply || files.isEmpty)) ||
          (reply
              ? articleContentCharacterCount(postBody) > 5000
              : !isArticleContentWithinLimit(postBody))) {
        throw StateError(reply ? '回复须为1至5000字符' : '正文须为1至500万字符');
      }
      if (postKind == 'article' &&
          utf8.encode(jsonEncode(rich.document.toDelta().toJson())).length >
              1800000) {
        throw StateError('文章内嵌图片较大，请缩小图片后重试');
      }
      if (!reply && cardDirty) await makeTextImage();
      if (!reply &&
          autoTextImage &&
          body.text.trim().isNotEmpty &&
          title.text.trim().isEmpty &&
          files.isEmpty &&
          postKind != 'article') {
        await makeTextImage();
      }
      if (!mounted) return;
      if (category == 'jieyuan') {
        if (title.text.trim().isEmpty) throw StateError('请填写物品名称');
        final c = await widget.repository.remote!.client.rpc(
          'jieyuan_permissions',
        );
        final p = c['permissions'] as Map;
        if (c['enabled'] != true ||
            p['publish'] != true ||
            p['enter'] != true ||
            c[jieyuan['type']] != true ||
            p[jieyuan['type']] != true) {
          throw StateError('当前等级或后台设置不允许此类结缘');
        }
        if (files.isNotEmpty &&
            (c['images'] != true ||
                c['resource_images'] != true ||
                p['images'] != true ||
                files.length > (p['max_images'] as num) ||
                files.any((f) => f['kind'] != 'image'))) {
          throw StateError('当前结缘图片权限或数量不允许上传');
        }
      }
      final attachments = await uploadFiles();
      await widget.repository.action(reply ? 'reply' : 'create', {
        'id': requestId,
        'body': postBody,
        'nickname': nickname.text.trim(),
        if (reply) 'post_id': widget.postId,
        'slug': widget.shareSlug,
        if (!reply) ...{
          'title': title.text.trim(),
          'category_id': category,
          if (category == 'jieyuan') 'jieyuan': jieyuan,
          'tags': tagList,
          'attachments': attachments,
          'post_kind': postKind,
          'access_level': accessLevel,
          'rich_body': postKind == 'article'
              ? rich.document.toDelta().toJson()
              : null,
          'source_note_id': widget.sourceNoteId,
        },
      });
      draftTimer?.cancel();
      await draftWrites.catchError((Object _) {});
      await draftStore!.write('published:$requestId', {
        ...snapshot(),
        'published': true,
      });
      await draftStore!.write(draftKey, {...snapshot(), 'published': true});
      if (mounted) {
        setState(() => finished = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('发布成功')));
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      await saveDraft().catchError((Object _) {});
      if (mounted) {
        setState(
          () => error =
              '发布失败，可以重新尝试。${e is StateError ? e.message : forumFailure(app, e)}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave() async {
    if (busy) return;
    draftTimer?.cancel();
    try {
      await saveDraft();
    } catch (_) {
      if (mounted) setState(() => error = '草稿保存失败，请重试，不要关闭页面。');
      return;
    }
    if (mounted) {
      setState(() => finished = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  ButtonStyle get entryStyle => TextButton.styleFrom(
    foregroundColor: const Color(0xffcf8e91),
    minimumSize: const Size(48, 52),
    textStyle: TextStyle(
      fontSize: (Theme.of(context).textTheme.labelLarge?.fontSize ?? 14) * 1.5,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: finished,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) leave();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: busy ? null : leave),
        title: Text(
          app.text(reply ? '回复帖子' : '发帖', reply ? 'Reply' : 'New post'),
        ),
        actions: [
          TextButton(
            key: const ValueKey('forum-publish'),
            style: entryStyle,
            onPressed: busy || !ready ? null : submit,
            child: Text(
              app.text(busy ? '提交中…' : '发布', busy ? 'Sending…' : 'Publish'),
            ),
          ),
        ],
      ),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          children: [
            if (!ready)
              TextButton(
                onPressed: loadDraft,
                child: const Text('正在读取草稿，点击重试'),
              ),
            if (!reply)
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    style: entryStyle,
                    onPressed: busy || !ready ? null : photoMenu,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('照片'),
                  ),
                  TextButton.icon(
                    style: entryStyle,
                    onPressed: busy || !ready ? null : previewTextImage,
                    icon: const Icon(Icons.text_fields),
                    label: const Text('文字生成图片'),
                  ),
                  TextButton(
                    onPressed: busy || !ready
                        ? null
                        : () {
                            setState(() => autoTextImage = false);
                            changed('');
                          },
                    child: const Text('普通文字'),
                  ),
                ],
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!reply) ...[
              if (!reply && category == 'jieyuan') ...[
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('结缘发布规则'),
                  children: [
                    Text(
                      jieyuanConfig['rules'] as String? ??
                          '禁止违法物品、危险品、武器、毒品、处方药、盗版侵权及诈骗信息。内部或限制传阅、需灌顶传承的资料不得擅自公开。',
                    ),
                  ],
                ),
                for (final warning in jieyuanConfig['warnings'] as List? ?? [])
                  Text('管理员提醒：$warning'),
              ],
              if (!reply && category == 'jieyuan')
                JieyuanFields(
                  enabled: !busy && ready,
                  currencies: List<String>.from(
                    jieyuanConfig['currencies'] as List? ??
                        ['CNY', 'NZD', 'AUD', 'USD'],
                  ),
                  value: jieyuan,
                  onChanged: (v) {
                    setState(() => jieyuan = v);
                    changed('');
                  },
                ),
              TextFormField(
                controller: title,
                enabled: !busy && ready,
                maxLength: 160,
                onChanged: changed,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  counterText: '',
                  labelText: category == 'jieyuan'
                      ? '物品名称'
                      : app.text('标题（选填）', 'Title (optional)'),
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (!reply && postKind == 'article') ...[
              AbsorbPointer(
                absorbing: busy || !ready,
                child: quill.QuillSimpleToolbar(
                  controller: rich,
                  config: const quill.QuillSimpleToolbarConfig(
                    multiRowsDisplay: false,
                  ),
                ),
              ),
              SizedBox(
                height:
                    (MediaQuery.sizeOf(context).height -
                            MediaQuery.viewInsetsOf(context).bottom -
                            250)
                        .clamp(220, 900),
                child: AbsorbPointer(
                  absorbing: busy || !ready,
                  child: SharedRichEditor(
                    controller: rich,
                    config: quill.QuillEditorConfig(
                      padding: const EdgeInsets.all(8),
                      embedBuilders: [NoteImageBuilder()],
                    ),
                  ),
                ),
              ),
            ] else
              TextFormField(
                controller: body,
                enabled: !busy && ready,
                onChanged: changed,
                minLines: 10,
                maxLines: null,
                // The shared rule counts Unicode code points. Do not use
                // TextField.maxLength here: Flutter counts grapheme clusters,
                // which would make emoji behave differently from Notes.
                maxLength: reply ? 5000 : null,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: app.text(
                    reply ? '写下你的回复…' : '写下想分享的内容…',
                    reply ? 'Write a reply…' : 'Share your reflections…',
                  ),
                ),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? app.text('请输入正文', 'Enter text')
                    : null,
              ),
            if (!reply) ...[
              TextFormField(
                controller: tags,
                enabled: !busy && ready,
                onChanged: changed,
                decoration: const InputDecoration(
                  labelText: '标签（逗号分隔，最多10个）',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                ),
              ),
              const Text('照片与文字图片按下方顺序发布；单个文件不超过10MB。草稿自动保存在本机。'),
              ExpansionTile(
                title: Text(app.text('更多设置', 'More settings')),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(app.text('纯文字自动配图', 'Automatic text image')),
                    subtitle: Text(
                      app.text(
                        '不填标题、不加照片时，发布会自动生成文字图片。',
                        'Without a title or photos, publishing generates a text image.',
                      ),
                    ),
                    value: autoTextImage,
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            autoTextImage = value;
                            changed('');
                          }),
                  ),

                  DropdownButtonFormField<String>(
                    initialValue: postKind,
                    decoration: InputDecoration(
                      labelText: app.text('发布类型', 'Type'),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'status', child: Text('发动态')),
                      DropdownMenuItem(value: 'image_text', child: Text('发图文')),
                      DropdownMenuItem(value: 'article', child: Text('写文章')),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() {
                              if (v == 'article' && postKind != 'article') {
                                rich.document =
                                    NoteRichContent.documentFromBody(body.text);
                              }
                              postKind = v!;
                            });
                            changed('');
                          },
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: accessLevel,
                    decoration: InputDecoration(
                      labelText: app.text('可见范围', 'Visibility'),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'public', child: Text('公开')),
                      DropdownMenuItem(
                        value: 'link_only',
                        child: Text('仅链接可见'),
                      ),
                      DropdownMenuItem(value: 'private', child: Text('私密')),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() => accessLevel = v!);
                            changed('');
                          },
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: InputDecoration(
                      labelText: app.text('分类', 'Category'),
                    ),
                    items: [
                      for (final e in widget.categories.entries)
                        if (e.key.isNotEmpty)
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(app.text(e.value[0], e.value[1])),
                          ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() => category = v!);
                            changed('');
                          },
                  ),
                  TextButton.icon(
                    onPressed: busy || !ready ? null : () => pick(false),
                    icon: const Icon(Icons.attach_file),
                    label: Text(app.text('附件', 'Attachment')),
                  ),
                ],
              ),
              for (var i = 0; i < files.length; i++)
                ListTile(
                  onTap: () => previewFile(files[i]),
                  leading: files[i]['kind'] == 'image'
                      ? Image.file(
                          File(files[i]['source'] as String),
                          width: 48,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image),
                        )
                      : const Icon(Icons.attach_file),
                  title: Text(
                    files[i]['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Wrap(
                    children: [
                      IconButton(
                        tooltip: '前移',
                        onPressed: busy || i == 0
                            ? null
                            : () {
                                setState(() {
                                  final f = files.removeAt(i);
                                  files.insert(i - 1, f);
                                });
                                changed('');
                              },
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: '后移',
                        onPressed: busy || i == files.length - 1
                            ? null
                            : () {
                                setState(() {
                                  final f = files.removeAt(i);
                                  files.insert(i + 1, f);
                                });
                                changed('');
                              },
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        tooltip: '从草稿移除',
                        onPressed: busy
                            ? null
                            : () {
                                setState(() => files.removeAt(i));
                                changed('');
                              },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
            ],
            FilledButton.icon(
              onPressed: busy || !ready ? null : submit,
              icon: const Icon(Icons.send_outlined),
              label: Text(app.text('发布', 'Publish')),
            ),
          ],
        ),
      ),
    ),
  );
}
