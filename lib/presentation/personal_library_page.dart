import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import '../services/apk_files.dart';
import '../services/resource_upload_policy.dart';
import 'note_reader_page.dart';
import 'note_share_actions.dart';
import 'chat_page.dart';

class PersonalLibraryPage extends StatefulWidget {
  const PersonalLibraryPage({
    super.key,
    required this.app,
    this.userId,
    required this.legacyPage,
  });
  final AppController app;
  final String? userId;
  final Widget legacyPage;
  @override
  State<PersonalLibraryPage> createState() => _LibraryState();
}

class _LibraryState extends State<PersonalLibraryPage> {
  SupabaseClient get client => widget.app.cloud!.client!;
  String get owner => widget.userId ?? client.auth.currentUser!.id;
  bool get own => owner == client.auth.currentUser?.id;
  NotesRepository get notes =>
      NotesRepository((widget.app.repository as SqliteCounterRepository).db);
  List<Map<String, dynamic>> rows = [];
  String? folder, error, pendingPath;
  String filter = '全部';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await client
          .from('personal_library_entries')
          .select('*,personal_library_assets(*)')
          .eq('owner_id', owner)
          .order('created_at', ascending: false);
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          rows = result;
          error = null;
          pendingPath = own ? prefs.getString('library.pending.$owner') : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '个人资料夹暂未连接，请重试。原有资料仍保留。');
      debugPrint('Personal library list: $e');
    }
  }

  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await task();
      await load();
    } catch (e) {
      debugPrint('Personal library: $e');
      if (mounted) {
        setState(
          () => error = resourceLimitMessage(e) ?? '操作未完成，可重试。本地原文件仍保留。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> insert(
    String title,
    String kind, {
    String? asset,
    String? source,
    String body = '',
    String? parent,
  }) async {
    await client.from('personal_library_entries').insert({
      'owner_id': owner,
      'parent_id': parent ?? folder,
      'title': title.isEmpty
          ? '未命名'
          : title.substring(0, title.length.clamp(0, 200)),
      'kind': kind,
      'asset_id': asset,
      'source_id': source,
      'body': body,
    });
  }

  Future<void> upload() async {
    if (pendingPath == null) {
      final picked = await FilePicker.platform.pickFiles();
      if (picked?.files.single.path == null) return;
      pendingPath = picked!.files.single.path;
      await (await SharedPreferences.getInstance()).setString(
        'library.pending.$owner',
        pendingPath!,
      );
    }
    final file = File(pendingPath!),
        name = pendingPath!.split(RegExp(r'[/\\]')).last;
    final size = await file.length();
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final args = {
      'p_name': name,
      'p_size': size,
      'p_hash': hash,
      'p_mime': isApk(name)
          ? 'application/vnd.android.package-archive'
          : 'application/octet-stream',
    };
    var asset = Map<String, dynamic>.from(
      await client.rpc('personal_library_upload', params: args),
    );
    if (asset['ready'] != true) {
      try {
        await client.storage
            .from('personal-library')
            .upload(
              asset['object_key'],
              file,
              fileOptions: FileOptions(contentType: args['p_mime'] as String),
            );
      } on StorageException catch (e) {
        if (e.statusCode != '409' &&
            !e.message.toLowerCase().contains('already exists')) {
          rethrow;
        }
      }
      asset = Map<String, dynamic>.from(
        await client.rpc(
          'personal_library_upload',
          params: {...args, 'p_complete': true},
        ),
      );
    }
    // Multiple folders point to one owner/hash asset; no duplicate Storage write.
    await insert(name, 'file', asset: asset['id']);
    await (await SharedPreferences.getInstance()).remove(
      'library.pending.$owner',
    );
    pendingPath = null;
  }

  Future<void> fromContent(bool article) async {
    List<Map<String, dynamic>> choices;
    if (article) {
      final data = await client.rpc(
        'community_profile_v1',
        params: {'p_user': owner},
      );
      choices = (data['posts'] as List)
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    } else {
      choices = (await notes.list())
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    }
    if (!mounted) return;
    final choice = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(c).height * .7,
          child: ListView(
            children: [
              for (final row in choices)
                ListTile(
                  title: Text(
                    (row['title'] as String? ?? '').isEmpty
                        ? (row['body'] as String? ?? '未命名')
                        : row['title'],
                    maxLines: 2,
                  ),
                  onTap: () => Navigator.pop(c, row),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    final full = article ? choice : await notes.get(choice['id']);
    await insert(
      full['title'] as String? ?? '',
      article ? 'article' : 'note',
      source: full['id'] as String,
      body: full['body'] as String? ?? '',
    );
  }

  String type(Map row) {
    if (row['kind'] == 'folder') return '文件夹';
    if (row['kind'] != 'file') return '文档';
    final name = (row['title'] as String).toLowerCase();
    if (RegExp(r'\.(png|jpg|jpeg|webp|gif|heic)$').hasMatch(name)) return '图片';
    if (RegExp(r'\.(pdf|docx?|txt|md|epub|xlsx?|pptx?)$').hasMatch(name)) {
      return '文档';
    }
    if (RegExp(r'\.(mp4|mov|webm|mkv)$').hasMatch(name)) return '视频';
    return '其他';
  }

  Future<void> open(Map<String, dynamic> row) async {
    if (row['kind'] == 'folder') {
      setState(() {
        folder = row['id'];
        filter = '全部';
      });
      return;
    }
    if (row['kind'] != 'file') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NoteReaderPage(
            storedNote: false,
            app: widget.app,
            body: row['body'],
            noteId: row['id'],
            scope: widget.app.scopeId,
            title: row['title'],
          ),
        ),
      );
      return;
    }
    final a = row['personal_library_assets'] as Map;
    final url = await client.storage
        .from('personal-library')
        .createSignedUrl(a['object_key'], 120);
    final dir = await getApplicationDocumentsDirectory();
    final apk = isApk(a['file_name']);
    final safeName = (a['file_name'] as String)
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
    final target = apk
        ? await ApkFiles.target(owner, a['id'], a['file_name'])
        : File('${dir.path}/library/${a['id']}/$safeName');
    final valid =
        await target.exists() &&
        await target.length() == a['file_size'] &&
        (await sha256.bind(target.openRead()).first).toString() ==
            a['checksum'];
    if (!valid) {
      await target.parent.create(recursive: true);
      final partial = File('${target.path}.partial');
      final transport = http.Client();
      try {
        final response = await transport.send(
          http.Request('GET', Uri.parse(url)),
        );
        if (response.statusCode != 200) {
          throw HttpException('Download ${response.statusCode}');
        }
        await response.stream.pipe(partial.openWrite());
        if (await partial.length() != a['file_size'] ||
            (await sha256.bind(partial.openRead()).first).toString() !=
                a['checksum']) {
          throw StateError('文件校验失败');
        }
        await partial.rename(target.path);
      } finally {
        transport.close();
      }
    }
    if (apk && Platform.isAndroid) {
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Android 安装包'),
          content: const Text('安装应用前，请确认文件来源可信。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('安装'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (yes != true) return;
      await ApkFiles.channel.invokeMethod('install', target.path);
      return;
    }
    await OpenFilex.open(target.path);
  }

  Future<void> action(Map<String, dynamic> row, String action) async {
    if (action == 'public') {
      await client
          .from('personal_library_entries')
          .update({'is_public': row['is_public'] != true})
          .eq('id', row['id'])
          .eq('owner_id', owner);
    }
    if (action == 'note') {
      await notes.save({'title': row['title'], 'body': row['body']});
    }
    if (action == 'article' && mounted) {
      await shareReadingNote(
        context,
        widget.app,
        'redbook',
        id: row['id'],
        title: row['title'],
        body: row['body'],
      );
    }
    if (action == 'copy') {
      if (!mounted) return;
      final dest = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(
          child: ListView(
            children: [
              for (final f in rows.where((e) => e['kind'] == 'folder'))
                ListTile(
                  title: Text(f['title']),
                  onTap: () => Navigator.pop(c, f['id']),
                ),
            ],
          ),
        ),
      );
      if (dest != null) {
        await insert(
          row['title'],
          row['kind'],
          parent: dest,
          asset: row['asset_id'],
          source: row['source_id'],
          body: row['body'],
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('个人资料夹'),
      actions: [
        IconButton(
          tooltip: '原有资料引用',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => widget.legacyPage),
          ),
          icon: const Icon(Icons.link),
        ),
        if (own)
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            onSelected: (v) => run(() async {
              if (v == 'upload') await upload();
              if (v == 'folder') {
                if (!context.mounted) return;
                final name = await chatText(context, '新建文件夹');
                if (name != null && name.trim().isNotEmpty) {
                  await insert(name, 'folder');
                }
              }
              if (v == 'note' || v == 'article') {
                await fromContent(v == 'article');
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'upload', child: Text('上传文件')),
              PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
              PopupMenuItem(value: 'note', child: Text('从笔记保存')),
              PopupMenuItem(value: 'article', child: Text('从文章保存')),
            ],
          ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          if (folder != null)
            TextButton(
              onPressed: () => setState(() => folder = null),
              child: const Text('返回全部资料'),
            ),
          Wrap(
            spacing: 4,
            children: [
              for (final v in ['全部', '文件夹', '图片', '文档', '视频', '其他'])
                ChoiceChip(
                  label: Text(v),
                  selected: filter == v,
                  onSelected: (_) => setState(() => filter = v),
                ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          if (own && pendingPath != null)
            ListTile(
              title: const Text('未完成上传 · 本地文件保留'),
              trailing: TextButton(
                onPressed: busy ? null : () => run(upload),
                child: const Text('重试'),
              ),
            ),
          for (final row in rows.where(
            (r) =>
                (!own || folder == null || r['parent_id'] == folder) &&
                (filter == '全部' || type(r) == filter),
          ))
            ListTile(
              leading: Icon(
                row['kind'] == 'folder'
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              title: Text(row['title']),
              subtitle: Text(
                row['is_public'] == true ? '公开（需开启主页资料夹总开关）' : '仅自己可见',
              ),
              onTap: () => run(() => open(row)),
              trailing: !own || row['kind'] == 'folder'
                  ? null
                  : PopupMenuButton<String>(
                      onSelected: (a) => run(() => action(row, a)),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'public',
                          child: Text(
                            row['is_public'] == true ? '设为私人' : '设为公开',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'copy',
                          child: Text('复制引用到文件夹'),
                        ),
                        if (row['kind'] != 'file')
                          const PopupMenuItem(
                            value: 'article',
                            child: Text('发布为文章'),
                          ),
                        if (row['kind'] != 'file')
                          const PopupMenuItem(
                            value: 'note',
                            child: Text('保存到笔记'),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    ),
  );
}
