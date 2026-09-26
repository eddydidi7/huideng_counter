import 'group_navigation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import '../services/attachment_service.dart';
import 'chat_page.dart';

class GroupPracticePage extends StatefulWidget {
  const GroupPracticePage({
    super.key,
    required this.app,
    required this.groupId,
    required this.title,
    this.projectId,
  });
  final AppController app;
  final String groupId, title;
  final String? projectId;
  @override
  State<GroupPracticePage> createState() => _GroupPracticePageState();
}

class _GroupPracticePageState extends State<GroupPracticePage> {
  late final api = AttachmentService(widget.app.cloud!.client!);
  Map<String, dynamic> data = {};
  String? error;
  bool busy = false;
  int pendingCounts = 0;
  Future<dynamic> call(String a, Map<String, dynamic> d) =>
      api.group(a, {'group_id': widget.groupId, ...d});
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await call('overview', {});
      final repo = widget.app.repository;
      if (repo is SqliteCounterRepository) {
        final waiting = await repo.db.rawQuery(
          'SELECT COUNT(*) AS n FROM practice_outbox WHERE group_id=?',
          [widget.groupId],
        );
        pendingCounts = (waiting.single['n'] as num).toInt();
      }
      if (mounted) setState(() => data = Map<String, dynamic>.from(d));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> run(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> join(Map p) async {
    final repo = widget.app.repository;
    final uid = widget.app.cloud!.client!.auth.currentUser!.id;
    if (widget.app.scopeId != uid || repo is! SqliteCounterRepository) {
      throw StateError('请先进入当前账号的计数空间');
    }
    String? project = widget.projectId;
    project ??= await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('选择计数项目：之后新增的计数计入本次共修')),
            for (final x in widget.app.projects)
              ListTile(
                title: Text(x.name),
                onTap: () => Navigator.pop(ctx, x.id),
              ),
          ],
        ),
      ),
    );
    if (project == null) return;
    await call('join_practice', {'id': p['id']});
    if (!identical(repo, widget.app.repository) || widget.app.scopeId != uid) {
      throw StateError('账号已变化');
    }
    await repo.db.rawInsert(
      'INSERT OR REPLACE INTO practice_links(project_id,practice_id,group_id,linked_at) VALUES(?,?,?,?)',
      [
        project,
        p['id'],
        widget.groupId,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已关联；之后新增的计数会自动提交，离线时排队。历史计数不重复提交。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.title} · 共修'),
      actions: [
        if (data['manager'] == true)
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => run(() async {
              final title = await chatText(context, '共修名称');
              if (title == null || !context.mounted) return;
              final target = await chatText(context, '目标遍数');
              final n = int.tryParse(target ?? '');
              if (n == null || n < 1) throw StateError('请输入正整数');
              await call('practice_create', {
                'id': const Uuid().v4(),
                'title': title,
                'target': n,
              });
            }),
          ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        children: [
          if (error != null) ListTile(title: Text(error!), onTap: load),
          if (busy) const LinearProgressIndicator(),
          if (pendingCounts > 0)
            ListTile(subtitle: Text('有 $pendingCounts 遍待提交。联网且仍有群权限时会自动重试。')),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('进入共修群'),
            onTap: () => openGroupChat(context, widget.app, widget.groupId),
          ),
          const ListTile(
            title: Text('计入本次共修'),
            subtitle: Text('每个计数项目同时关联一项共修；新的计数才计入。断网后会自动补交。'),
          ),
          for (final p in data['practices'] as List? ?? [])
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p['title'],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '参加 ${p['participants']} 人 · 总计 ${p['total']} / ${p['target']} · 我的贡献 ${p['mine']}',
                    ),
                    LinearProgressIndicator(
                      value: ((p['total'] as num) / (p['target'] as num))
                          .clamp(0, 1)
                          .toDouble(),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => run(() => join(p)),
                      child: const Text('参加并关联计数项目'),
                    ),
                  ],
                ),
              ),
            ),
          TextButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    final repo = widget.app.repository;
                    if (repo is SqliteCounterRepository) {
                      await repo.db.delete(
                        'practice_links',
                        where: 'group_id=?',
                        whereArgs: [widget.groupId],
                      );
                    }
                  }),
            child: const Text('停止将新计数计入本群共修'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回群资料'),
          ),
        ],
      ),
    ),
  );
}

Future<void> choosePracticeGroup(
  BuildContext context,
  AppController app, {
  String? projectId,
}) async {
  try {
    if (app.cloud?.client?.auth.currentUser == null) throw StateError('请先连接账号');
    final api = AttachmentService(app.cloud!.client!);
    final groups = List<dynamic>.from(await api.group('my_groups', {}) as List);
    final linked = <String>{};
    if (projectId != null && app.repository is SqliteCounterRepository) {
      final records = await (app.repository as SqliteCounterRepository).db.query(
        'practice_links', columns: ['group_id'], where: 'project_id=?', whereArgs: [projectId]);
      linked.addAll(records.map((r) => r['group_id'] as String));
      groups.sort((a, b) => (linked.contains(b['id']) ? 1 : 0).compareTo(linked.contains(a['id']) ? 1 : 0));
    }
    if (!context.mounted) return;
    final g = await showModalBottomSheet<Map>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('相关共修群')),
            if (groups.isEmpty) const ListTile(title: Text('请先加入一个群聊')),
            for (final g in groups)
              ListTile(
                title: Text(g['title'] ?? g['name'] ?? '群聊'),
                trailing: TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await openGroupChat(context, app, g['id']);
                  },
                  child: const Text('进入群聊 ›'),
                ),
                subtitle: Text(linked.contains(g['id']) ? '已关联此计数项目 · 点击群名查看共修' : '点击群名设置共修关联'),
                onTap: () => Navigator.pop(ctx, g),
              ),
          ],
        ),
      ),
    );
    if (g != null && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupPracticePage(
            app: app,
            groupId: g['id'],
            title: g['title'] ?? g['name'] ?? '群聊',
            projectId: projectId,
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
