import 'common_shortcut.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../domain/models.dart';
import 'counter_page.dart';
import 'history_page.dart';
import 'project_editor.dart';
import 'settings_page.dart';
import 'notices_page.dart';
import 'shared.dart';

class HomePage extends StatefulWidget {
  final AppController app;
  const HomePage({super.key, required this.app});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppController get app => widget.app;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  Future<void> refresh() async {
    try {
      await app.reload();
    } catch (e) {
      if (mounted) showFailure(context, app, e);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void open(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  Future<void> action(String action, CounterProject project) async {
    if (action == 'edit') {
      open(ProjectEditor(app: app, project: project));
      return;
    }
    if (action == 'history') {
      open(HistoryPage(app: app, project: project));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.text('删除项目？', 'Delete project?')),
        content: Text(
          app.text(
            '“${project.name}”及其记录将从列表隐藏，并保留软删除标记。',
            '“${project.name}” and its records will be hidden and marked as deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(app.text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(app.text('删除', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await app.repository.deleteProject(project.id);
        await app.reload();
      } catch (e) {
        if (mounted) showFailure(context, app, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (_, _) {
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 40,
          leadingWidth: 64,
          leading: CommonShortcut(app: app),
          titleSpacing: 4,
          title: Text(
            app.text('文殊计数器', 'Manjushri Counter'),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize:
                  (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) *
                  0.8 *
                  0.88,
            ),
          ),
          actions: [
            IconButton(
              tooltip: app.text('设置', 'Settings'),
              onPressed: () => open(SettingsPage(app: app)),
              icon: const Icon(Icons.settings_outlined),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  key: const ValueKey('home-notices-panel'),
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: NoticesPage(
                    app: app,
                    embedded: true,
                    compactHeader: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.text('我的计数项目', 'My counters'),
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontSize:
                                        (Theme.of(
                                              context,
                                            ).textTheme.titleLarge?.fontSize ??
                                            22) *
                                        0.6,
                                  ),
                            ),
                            Text(
                              app.text('长按项目拖动排序', 'Hold a counter to reorder'),
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(height: 1.2),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => open(ProjectEditor(app: app)),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.add, size: 20),
                        label: Text(app.text('新建项目', 'New counter')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: app.projects.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.add_circle_outline,
                                size: 56,
                                color: Color(0xff9b8058),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                app.text(
                                  '开始第一个计数项目',
                                  'Create your first counter',
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                app.text(
                                  '每一次念诵，都会妥善保存。',
                                  'Every recitation is saved locally.',
                                ),
                              ),
                            ],
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final normalText =
                                MediaQuery.textScalerOf(context).scale(14) <=
                                18.2;
                            final rowHeight = ((constraints.maxHeight - 12) / 6)
                                .clamp(48.0, 80.0);
                            final compact = normalText;
                            return ReorderableListView.builder(
                              itemExtent: compact ? rowHeight : null,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              buildDefaultDragHandles: false,
                              itemCount: app.projects.length,
                              onReorderItem: (oldIndex, newIndex) async {
                                final ids = app.projects
                                    .map((p) => p.id)
                                    .toList();
                                ids.insert(newIndex, ids.removeAt(oldIndex));
                                try {
                                  await app.repository.reorder(ids);
                                  await app.reload();
                                } catch (e) {
                                  if (context.mounted) {
                                    showFailure(context, app, e);
                                  }
                                }
                              },
                              itemBuilder: (context, index) {
                                final p = app.projects[index];
                                return ReorderableDelayedDragStartListener(
                                  key: ValueKey(p.id),
                                  index: index,
                                  child: Card(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    elevation: 0,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surface,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => open(
                                        CounterPage(app: app, project: p),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 2,
                                        ),
                                        child: Row(
                                          children: [
                                            ProjectImage(
                                              path: p.imagePath,
                                              size: compact
                                                  ? (rowHeight - 8).clamp(
                                                      36.0,
                                                      56.0,
                                                    )
                                                  : 64,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    p.name,
                                                    maxLines: compact ? 1 : 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(height: 1.2),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  if (compact)
                                                    Text(
                                                      '${app.text('今日', 'Today')} ${p.today}  ·  ${app.text('累计', 'Total')} ${p.displayTotal}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            height: 1.2,
                                                          ),
                                                    )
                                                  else
                                                    Wrap(
                                                      spacing: 10,
                                                      children: [
                                                        Text(
                                                          '${app.text('今日', 'Today')}  ${p.today}',
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                    height: 1.2,
                                                                  ),
                                                        ),
                                                        Text(
                                                          '${app.text('累计', 'Total')}  ${p.displayTotal}',
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                    height: 1.2,
                                                                  ),
                                                        ),
                                                      ],
                                                    ),
                                                  if (!compact)
                                                    const SizedBox(height: 2),
                                                  if (!compact)
                                                    Text(
                                                      '${app.text('最近', 'Last')}  ${stamp(p.lastRecitedAt)}',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            height: 1.2,
                                                          ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  width: 44,
                                                  height: compact
                                                      ? rowHeight - 8
                                                      : 32,
                                                  child:
                                                      PopupMenuButton<String>(
                                                        padding:
                                                            EdgeInsets.zero,
                                                        tooltip: app.text(
                                                          '更多',
                                                          'More',
                                                        ),
                                                        onSelected: (value) =>
                                                            action(value, p),
                                                        itemBuilder: (_) => [
                                                          PopupMenuItem(
                                                            value: 'edit',
                                                            child: Text(
                                                              app.text(
                                                                '编辑',
                                                                'Edit',
                                                              ),
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value: 'history',
                                                            child: Text(
                                                              app.text(
                                                                '历史记录',
                                                                'History',
                                                              ),
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value: 'delete',
                                                            child: Text(
                                                              app.text(
                                                                '删除',
                                                                'Delete',
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                ),
                                                if (!compact)
                                                  ReorderableDragStartListener(
                                                    index: index,
                                                    child: Container(
                                                      color: Colors.transparent,
                                                      width: 44,
                                                      height: 32,
                                                      child: Center(
                                                        child: Icon(
                                                          Icons.drag_handle,
                                                          semanticLabel: app.text(
                                                            '拖动排序',
                                                            'Drag to reorder',
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
