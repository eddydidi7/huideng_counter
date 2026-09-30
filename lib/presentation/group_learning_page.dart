import '../services/chat_apk_storage.dart';
import '../services/apk_files.dart';
import 'apk_file_card.dart';
import 'group_file_share.dart';
import 'routed_image.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../services/attachment_service.dart';
import '../services/solar_reminder_service.dart';
import 'chat_page.dart';
import 'group_practice_page.dart';

class GroupLearningPage extends StatefulWidget {
  const GroupLearningPage({
    super.key,
    required this.app,
    required this.groupId,
    required this.title,
  });
  final AppController app;
  final String groupId, title;
  @override
  State<GroupLearningPage> createState() => _GroupLearningPageState();
}

class _GroupLearningPageState extends State<GroupLearningPage> {
  late final files = AttachmentService(widget.app.cloud!.client!);
  Map<String, dynamic> data = {};
  String tab = 'files', query = '';
  String? folder, error;
  bool busy = false;
  bool get manager => data['manager'] == true;
  Future<dynamic> action(String a, [Map<String, dynamic> d = const {}]) =>
      files.group(a, {'group_id': widget.groupId, ...d});
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final value = await action('overview');
      if (mounted) {
        setState(() {
          data = Map<String, dynamic>.from(value);
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法加载群资料，请重试');
    }
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
      await refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作未完成：$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> upload() async {
    final choice = await FilePicker.platform.pickFiles(
      type: tab == 'album' ? FileType.image : FileType.any,
    );
    if (choice == null || choice.files.single.path == null) return;
    await run(
      () => files.uploadGroup(
        widget.groupId,
        choice.files.single.path!,
        choice.files.single.name,
        album: tab == 'album',
        folderId: folder,
      ),
    );
  }

  Future<void> create() async {
    final title = await chatText(
      context,
      tab == 'files' || tab == 'album' ? '新建文件夹' : '标题',
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    if (tab == 'files' || tab == 'album') {
      await run(() async {
        await action('folder', {'id': const Uuid().v4(), 'name': title});
      });
      return;
    }
    final body = await chatText(context, '内容');
    if (body == null || !mounted) return;
    DateTime? start;
    if (tab == 'event') {
      final day = await showDatePicker(
        context: context,
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 1825)),
      );
      if (day == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );
      if (time == null) return;
      start = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    }
    await run(() async {
      await action('content', {
        'id': const Uuid().v4(),
        'kind': tab,
        'title': title,
        'body': body,
        'start_at': start?.toUtc().toIso8601String(),
      });
    });
  }

  Future<void> configure() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in {
              'all_muted': '全群禁言',
              'allow_upload': '允许成员上传',
              'history_files': '新成员可读历史文件',
              'member': '管理成员 / 禁言',
            }.entries)
              ListTile(
                title: Text(e.value),
                trailing: e.key == 'member'
                    ? const Icon(Icons.chevron_right)
                    : Icon(
                        (data['settings']?[e.key] ?? (e.key != 'all_muted')) ==
                                true
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                      ),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result == 'member') {
      final roster =
          await widget.app.cloud!.client!.rpc(
                'chat_api_v1',
                params: {
                  'p_action': 'members',
                  'p_data': {'room_id': widget.groupId},
                },
              )
              as List;
      if (!mounted) return;
      final user = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            children: [
              for (final m in roster)
                ListTile(
                  title: Text(m['nickname']),
                  onTap: () => Navigator.pop(ctx, m['user_id']),
                ),
            ],
          ),
        ),
      );
      if (user == null || !mounted) return;
      final command = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in {
                'hour': '禁言1小时',
                'day': '禁言1天',
                'forever': '永久禁言',
                'unmute': '解除禁言',
                if (data['owner'] == true) 'admin': '设为管理员',
                if (data['owner'] == true) 'member': '取消管理员',
                'remove': '移出群聊',
              }.entries)
                ListTile(
                  title: Text(e.value),
                  onTap: () => Navigator.pop(ctx, e.key),
                ),
            ],
          ),
        ),
      );
      if (command == null) return;
      await run(() async {
        if (command == 'admin' || command == 'member') {
          await action('role', {'user_id': user, 'role': command});
        } else if (command == 'remove') {
          await action('remove_member', {'user_id': user});
        } else {
          await action('mute', {
            'user_id': user,
            'until': command == 'forever'
                ? 'infinity'
                : command == 'unmute'
                ? null
                : DateTime.now()
                      .add(Duration(hours: command == 'hour' ? 1 : 24))
                      .toUtc()
                      .toIso8601String(),
          });
        }
      });
    } else {
      final settings = Map<String, dynamic>.from(data['settings'] ?? {});
      final defaults = {
        'all_muted': false,
        'allow_upload': true,
        'history_files': true,
      };
      await run(() async {
        await action('settings', {
          ...defaults,
          ...settings,
          result: !(settings[result] as bool? ?? defaults[result]!),
        });
      });
    }
  }

  Future<void> editFolder(Map f) async {
    final name = await chatText(context, '文件夹名称', initial: f['name']);
    if (name == null || !mounted) return;
    final order = await chatText(
      context,
      '排序（数字越小越靠前）',
      initial: '${f['position']}',
    );
    final position = int.tryParse(order ?? '');
    if (position == null) return;
    await run(() async {
      await action('folder', {
        'id': f['id'],
        'name': name,
        'position': position,
      });
    });
  }

  Future<void> search() async {
    final text = await chatText(context, '搜索聊天、文件、公告、成员、精华');
    if (text == null || text.trim().isEmpty) return;
    await run(() async {
      final result = await action('search', {'query': text});
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .75,
            child: ListView(
              children: [
                for (final key in [
                  'messages',
                  'files',
                  'items',
                  'members',
                ]) ...[
                  ListTile(
                    title: Text(
                      {
                        'messages': '聊天',
                        'files': '文件',
                        'items': '公告 / 精华 / 活动',
                        'members': '成员',
                      }[key]!,
                    ),
                  ),
                  for (final r in result[key] as List)
                    ListTile(
                      title: SelectableText(
                        '${r['title'] ?? r['file_name'] ?? r['nickname'] ?? r['body']}',
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFiles = tab == 'files' || tab == 'album';
    final rows = isFiles
        ? (data['files'] as List? ?? []).where(
            (f) =>
                f['album'] == (tab == 'album') &&
                (folder == null || f['folder_id'] == folder),
          )
        : (data['items'] as List? ?? []).where((i) => i['kind'] == tab);
    return Scaffold(
      appBar: AppBar(
        bottom: busy
            ? PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: ValueListenableBuilder<Map<String, double>>(
                  valueListenable: ChatApkStorage.progress,
                  builder: (_, values, _) => Text(
                    values.isEmpty
                        ? ''
                        : 'APK 上传 ${(values.values.first * 100).floor()}%',
                  ),
                ),
              )
            : null,
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: busy ? null : search,
            icon: const Icon(Icons.search),
          ),
          if (manager)
            IconButton(
              onPressed: busy ? null : configure,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in {
                    'files': '群文件',
                    'album': '群相册',
                    'announcement': '群公告',
                    'highlight': '群精华',
                    'event': '日程活动',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: ChoiceChip(
                        label: Text(e.value),
                        selected: tab == e.key,
                        onSelected: (_) => setState(() => tab = e.key),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: const Text('群共修'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupPracticePage(
                    app: widget.app,
                    groupId: widget.groupId,
                    title: widget.title,
                  ),
                ),
              ),
            ),
            if (error != null) ListTile(title: Text(error!), onTap: refresh),
            if (isFiles)
              Wrap(
                children: [
                  ActionChip(
                    label: const Text('全部文件夹'),
                    onPressed: () => setState(() => folder = null),
                  ),
                  for (final f in data['folders'] as List? ?? [])
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: GestureDetector(
                        onLongPress: manager ? () => editFolder(f) : null,
                        child: ChoiceChip(
                          label: Text(f['name']),
                          selected: folder == f['id'],
                          onSelected: (_) => setState(() => folder = f['id']),
                        ),
                      ),
                    ),
                ],
              ),
            Row(
              children: [
                if (isFiles)
                  TextButton.icon(
                    onPressed: busy ? null : upload,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('上传'),
                  ),
                if (manager)
                  TextButton.icon(
                    onPressed: busy ? null : create,
                    icon: const Icon(Icons.add),
                    label: Text(isFiles ? '新建文件夹' : '发布'),
                  ),
              ],
            ),
            if (busy) const LinearProgressIndicator(),
            if (isFiles && (data['files'] as List? ?? []).length >= 500)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          final more =
                              await action('more_files', {
                                    'offset': (data['files'] as List).length,
                                  })
                                  as List;
                          if (mounted) {
                            setState(
                              () => data['files'] = [...data['files'], ...more],
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                      },
                child: const Text('加载更早的群文件'),
              ),
            for (final raw in rows)
              ListTile(
                leading: isFiles && tab == 'album'
                    ? GroupFileThumbnail(files: files, fileId: raw['file_id'])
                    : Icon(
                        isFiles
                            ? Icons.description_outlined
                            : raw['is_pinned'] == true
                            ? Icons.push_pin
                            : Icons.article_outlined,
                      ),
                title: Text(raw['file_name'] ?? raw['title']),
                subtitle: Text(
                  isFiles
                      ? '${((raw['file_size'] as num) / 1048576).toStringAsFixed(1)} MB'
                      : '${raw['body']}\n${raw['created_at']}${tab == 'announcement' ? ' · 已读 ${raw['read_count']}' : ''}',
                ),
                onTap: () => run(() async {
                  if (isFiles && isApk(raw['file_name'] as String)) {
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        content: SizedBox(
                          width: 320,
                          child: ApkFileCard(
                            name: raw['file_name'],
                            size: (raw['file_size'] as num).toInt(),
                            guard: files.guard,
                            createdAt: raw['created_at'],
                            load: (changed) =>
                                raw['bucket'] == 'public-resources'
                                ? files.download(raw)
                                : ApkFiles.download(
                                    owner: files.owner,
                                    id: raw['file_id'],
                                    name: raw['file_name'],
                                    size: (raw['file_size'] as num).toInt(),
                                    checksum: raw['checksum'],
                                    guard: files.guard,
                                    progress: changed,
                                    url: () => files.client.storage
                                        .from(raw['bucket'])
                                        .createSignedUrl(
                                          raw['object_key'],
                                          300,
                                        ),
                                  ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  } else if (isFiles) {
                    await OpenFilex.open(
                      await files.download(Map<String, dynamic>.from(raw)),
                    );
                  } else {
                    await action('read', {'id': raw['id']});
                    if (context.mounted) {
                      await showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(raw['title']),
                          content: SingleChildScrollView(
                            child: SelectableText(raw['body']),
                          ),
                          actions: [
                            if (tab == 'event' && raw['start_at'] != null)
                              TextButton(
                                onPressed: () async {
                                  await SolarReminderService.instance
                                      .remindChat(
                                        widget.groupId,
                                        raw['title'],
                                        DateTime.parse(raw['start_at']),
                                      );
                                  if (ctx.mounted) Navigator.pop(ctx);
                                },
                                child: const Text('活动开始时提醒我'),
                              ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      );
                    }
                  }
                }),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) => run(() async {
                    if (v == 'public') {
                      await publishGroupFile(
                        context,
                        files,
                        Map<String, dynamic>.from(raw),
                      );
                      return;
                    }
                    if (v == 'remove') {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('从群资料移除？'),
                          content: const Text('将停止成员访问；存储文件保留，交由后台后续清理。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('移除'),
                            ),
                          ],
                        ),
                      );
                      if (yes == true) {
                        await action(
                          isFiles ? 'file_remove' : 'content_remove',
                          {'id': raw['id']},
                        );
                      }
                    }
                    if (v == 'pin') {
                      await action('content', {
                        ...Map<String, dynamic>.from(raw),
                        'is_pinned': raw['is_pinned'] != true,
                      });
                    }
                    if (v == 'save') {
                      await action('save_reference', {
                        'kind': 'group_file',
                        'source_id': raw['file_id'],
                        'title': raw['file_name'],
                        'metadata': {'group_id': widget.groupId},
                      });
                    }
                    if (v == 'move' && context.mounted) {
                      final selected = await showModalBottomSheet<String>(
                        context: context,
                        builder: (ctx) => SafeArea(
                          child: ListView(
                            children: [
                              ListTile(
                                title: const Text('根目录'),
                                onTap: () => Navigator.pop(ctx, ''),
                              ),
                              for (final f in data['folders'] as List? ?? [])
                                ListTile(
                                  title: Text(f['name']),
                                  onTap: () => Navigator.pop(ctx, f['id']),
                                ),
                            ],
                          ),
                        ),
                      );
                      if (selected != null) {
                        await action('file_move', {
                          'id': raw['id'],
                          'folder_id': selected,
                        });
                      }
                    }
                  }),
                  itemBuilder: (_) => [
                    if (isFiles)
                      const PopupMenuItem(
                        value: 'public',
                        child: Text('转存到公共网盘'),
                      ),
                    if (isFiles)
                      const PopupMenuItem(
                        value: 'save',
                        child: Text('保存到个人资料夹'),
                      ),
                    if (manager && isFiles)
                      const PopupMenuItem(value: 'move', child: Text('移动到文件夹')),
                    if (manager && !isFiles)
                      const PopupMenuItem(
                        value: 'pin',
                        child: Text('置顶 / 取消置顶'),
                      ),
                    if (manager)
                      const PopupMenuItem(value: 'remove', child: Text('移除')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GroupFileThumbnail extends StatefulWidget {
  const GroupFileThumbnail({
    super.key,
    required this.files,
    required this.fileId,
  });
  final AttachmentService files;
  final String fileId;
  @override
  State<GroupFileThumbnail> createState() => _GroupFileThumbnailState();
}

class _GroupFileThumbnailState extends State<GroupFileThumbnail> {
  late final future = widget.files.downloadUrl(widget.fileId);
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 56,
    height: 56,
    child: FutureBuilder<String>(
      future: future,
      builder: (context, snapshot) => snapshot.hasData
          ? RoutedImage(
              snapshot.data!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            )
          : const Icon(Icons.image_outlined),
    ),
  );
}
