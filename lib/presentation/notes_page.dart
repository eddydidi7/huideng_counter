import 'adaptive_action_bar.dart';
import 'note_categories_page.dart';
import 'note_typography_page.dart';
import 'large_note_editor.dart';
import 'note_reader_page.dart';
import 'shared_rich_editor.dart';
import 'forum_compose_page.dart';
import 'forum_page.dart';
import 'forum_chat_share.dart';
import '../data/repositories/forum_repository.dart';
import '../data/remote/forum_remote.dart';
import '../data/local/home_message_cache.dart';
import 'note_grid.dart';
import 'note_actions_menu.dart';
import 'note_list_share.dart';
import 'note_search_page.dart';
import '../services/note_export.dart';
import '../core/sync_diagnostics.dart';
import 'published_notes_page.dart';
import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import 'note_rich_content.dart';

class NotesPage extends StatefulWidget {
  final AppController app;
  final String initialFolder;
  const NotesPage({
    super.key,
    required this.app,
    this.initialFolder = 'active',
  });
  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String search = '', folder = 'active', sort = 'updatedAt';
  bool grid = false;
  bool sortAscending = false;
  final selected = <String>{};
  final selectedStates = <String, Map<String, Object?>>{};
  late Future<List<Map<String, Object?>>> rows;
  AppController get app => widget.app;
  NotesRepository get repository =>
      NotesRepository((app.repository as SqliteCounterRepository).db);
  @override
  void initState() {
    super.initState();
    folder = widget.initialFolder;
    refresh();
  }

  void refresh() {
    rows = folder == 'published'
        ? Future.value([])
        : repository
              .list(
                search: search,
                folder: folder,
                sort: sort,
                ascending: sortAscending,
              )
              .then(
                (list) => folder == 'quick'
                    ? list.where(NotesRepository.isQuickAccess).toList()
                    : category == null
                    ? list
                    : list
                          .where(
                            (row) => category!.isEmpty
                                ? NotesRepository.categoriesOf(row).isEmpty
                                : NotesRepository.categoriesOf(
                                    row,
                                  ).contains(category),
                          )
                          .toList(),
              );
  }

  /// Category shown by the current folder ('' = uncategorized), else null.
  String? get category => folder == 'uncategorized'
      ? ''
      : folder.startsWith('notebook:')
      ? folder.substring(9)
      : null;

  @override
  void didUpdateWidget(covariant NotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    refresh();
  }

  void update(VoidCallback change) => setState(() {
    change();
    refresh();
  });

  bool get selecting => selected.isNotEmpty;

  bool singleSelectedHas(String field) =>
      selected.length == 1 && selectedStates[selected.single]?[field] == 1;

  void select(Map<String, Object?> note) => setState(() {
    final id = note['id'] as String;
    selectedStates[id] = note;
    if (!selected.add(id)) selected.remove(id);
  });

  void selectAll(List<Map<String, Object?>> notes) => setState(() {
    selectedStates.addEntries(notes.map((n) => MapEntry(n['id'] as String, n)));
    if (selected.length == notes.length) {
      selected.clear();
    } else {
      selected
        ..clear()
        ..addAll(notes.map((note) => note['id'] as String));
    }
  });

  Future<void> selectAllCurrent() async {
    final notes = await rows;
    if (mounted) selectAll(notes);
  }

  Future<void> bulkChange(String action) async {
    final ids = selected.toList(growable: false);
    if (ids.isEmpty) return;
    if (action == 'category_add') {
      await addToNotebooks(ids);
      return;
    }
    if (action == 'category') {
      final chosen = await pickNoteCategory(context, app, repository);
      if (chosen == null) return;
      try {
        await repository.setCategory(ids, chosen);
        if (!mounted) return;
        update(selected.clear);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已将 ${ids.length} 篇笔记移到“${chosen.isEmpty ? '未分类' : chosen}”',
            ),
          ),
        );
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('移动未完成，笔记未删除。请重试。')));
          update(() {});
        }
      }
      return;
    }
    if (action == 'trash') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(app.text('移入回收站？', 'Move to trash?')),
          content: Text(
            app.text(
              '已选择的笔记仍可在回收站恢复。',
              'Selected notes can be restored from Trash.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.text('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.text('移入回收站', 'Move to trash')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      for (final id in ids) {
        final note = await repository.get(id);
        final next = <String, Object?>{...note};
        switch (action) {
          case 'pin':
            next['isPinned'] = 1;
            break;
          case 'unpin':
            next['isPinned'] = 0;
            break;
          case 'favorite':
            next['isFavorite'] = 1;
            break;
          case 'unfavorite':
            next['isFavorite'] = 0;
            break;
          case 'archive':
            next['isArchived'] = 1;
            break;
          case 'unarchive':
            next['isArchived'] = 0;
            break;
          case 'trash':
            next['deletedAt'] = DateTime.now().toUtc().toIso8601String();
            break;
        }
        await repository.save(next);
      }
      if (mounted) update(selected.clear);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              app.text(
                '批量操作未完成，本地数据未删除。',
                'Bulk action was not completed. Local data is retained.',
              ),
            ),
          ),
        );
      }
    }
  }

  String noteSummary(Map<String, Object?> note) {
    final body = NoteRichContent.plainText(
      note['body'] as String? ?? '',
    ).trim();
    final text = body.isEmpty
        ? (note['title'] as String? ?? '')
        : body.split('\n').first;
    return text.isEmpty
        ? app.text('空白笔记', 'Empty note')
        : String.fromCharCodes(text.runes.take(40));
  }

  Future<void> edit([
    Map<String, Object?>? note,
    List<Map<String, Object?>>? siblings,
    int? index,
  ]) async {
    if (note != null) note = await repository.get(note['id'] as String);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => (note?['body'] as String? ?? '').length > 100000
            ? LargeNoteEditor(
                app: app,
                repository: repository,
                note: note!,
                siblings: siblings,
                siblingIndex: index,
              )
            : NoteEditor(
                app: app,
                repository: repository,
                note: note,
                siblings: siblings,
                siblingIndex: index,
              ),
      ),
    );
    if (mounted) update(() {});
  }

  Future<void> change(Map<String, Object?> row, String action) async {
    if (action == 'category_add') {
      await addToNotebooks([row['id'] as String]);
      return;
    }
    if (action == 'select') {
      select(row);
      return;
    }
    if (action == 'share' || action == 'quick') {
      try {
        final note = await repository.get(row['id'] as String);
        if (!mounted) return;
        if (action == 'share') {
          await shareNoteFromList(context, app, note);
        } else {
          await repository.setQuickAccess(
            note['id'] as String,
            !NotesRepository.isQuickAccess(note),
          );
          if (mounted) update(() {});
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('操作未完成，请重试。笔记未删除。')));
        }
      }
      return;
    }
    if (action == 'category') {
      final chosen = await pickNoteCategory(
        context,
        app,
        repository,
        current: NotesRepository.categoryOf(row),
      );
      if (chosen == null) return;
      try {
        await repository.setCategory([row['id'] as String], chosen);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('移动未完成，笔记未改动。请重试。')));
        }
      }
      if (mounted) update(() {});
      return;
    }
    try {
      final next = {...await repository.get(row['id'] as String)};
      if (!mounted) return;
      if (action == 'trash') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(app.text('移入回收站？', 'Move to trash?')),
            content: Text(
              app.text('笔记仍可恢复，不会永久删除。', 'You can restore this note later.'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(app.text('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(app.text('移入回收站', 'Move to trash')),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        next['deletedAt'] = DateTime.now().toUtc().toIso8601String();
      } else if (action == 'restore') {
        next['deletedAt'] = null;
      } else {
        next[action] = next[action] == 1 ? 0 : 1;
      }
      await repository.save(next);
      if (mounted) update(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              app.text(
                '保存失败，请刷新后重试。',
                'Could not save. Refresh and try again.',
              ),
            ),
          ),
        );
      }
    }
  }

  final scaffoldKey = GlobalKey<ScaffoldState>();
  Future<void> addToNotebooks(List<String> ids) async {
    try {
      final chosen = await pickNoteCategories(context, app, repository);
      if (chosen == null || chosen.isEmpty) return;
      await repository.addCategories(ids, chosen);
      if (mounted) update(selected.clear);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('添加未完成，请重试。笔记未删除。')));
      }
    }
  }

  Future<void> quickMenu(Map<String, Object?> row) async {
    if (selecting) {
      select(row);
      return;
    }
    final action = await showNoteActionMenu(
      context,
      noteQuickActions(row, trash: folder == 'trash'),
    );
    if (action != null && mounted) await change(row, action);
  }

  Map<String, String> get folders => {
    'active': app.text('所有笔记', 'All notes'),
    'published': app.text('资料', 'Resources'),
    'favorites': app.text('收藏', 'Favorites'),
    'quick': app.text('快速访问', 'Quick access'),
    'archive': app.text('归档', 'Archive'),
    'trash': app.text('回收站', 'Trash'),
  };

  Future<void> searchNotes() async {
    final input = TextEditingController(text: search);
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(app.text('搜索笔记', 'Search notes')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(
            hintText: app.text('搜索正文或旧标题', 'Search text or old titles'),
          ),
          onSubmitted: (value) => Navigator.pop(c, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(app.text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, input.text),
            child: Text(app.text('搜索', 'Search')),
          ),
        ],
      ),
    );
    // Allow the closing dialog animation to dispose its TextField first.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null && mounted) update(() => search = value.trim());
  }

  Future<void> openCategories() async {
    final chosen = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            NoteCategoriesPage(app: app, notes: repository, current: folder),
      ),
    );
    if (!mounted) return;
    update(() {
      if (chosen != null) {
        folder = chosen;
        search = '';
      }
    });
  }

  Future<void> chooseSort() async {
    final options = <(String, String, bool)>[
      ('updatedAt', app.text('修改时间 · 最新在前', 'Modified · Newest first'), false),
      ('updatedAt', app.text('修改时间 · 最旧在前', 'Modified · Oldest first'), true),
      ('createdAt', app.text('创建时间 · 最新在前', 'Created · Newest first'), false),
      ('createdAt', app.text('创建时间 · 最旧在前', 'Created · Oldest first'), true),
      ('title', app.text('标题 · 正序 A→Z', 'Title · A to Z'), true),
      ('title', app.text('标题 · 倒序 Z→A', 'Title · Z to A'), false),
    ];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                app.text('笔记排序', 'Sort notes'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final option in options)
              ListTile(
                title: Text(option.$2),
                selected: sort == option.$1 && sortAscending == option.$3,
                trailing: sort == option.$1 && sortAscending == option.$3
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  Navigator.pop(c);
                  update(() {
                    sort = option.$1;
                    sortAscending = option.$3;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget notesMenu() => Drawer(
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          ListTile(
            title: Text(
              app.text('笔记菜单', 'Notes menu'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final entry in folders.entries)
            ListTile(
              leading: Icon(switch (entry.key) {
                'published' => Icons.campaign_outlined,
                'favorites' => Icons.star_outline,
                'quick' => Icons.bolt_outlined,
                'archive' => Icons.archive_outlined,
                'trash' => Icons.delete_outline,
                _ => Icons.notes,
              }),
              title: Text(entry.value),
              selected: folder == entry.key,
              onTap: () {
                scaffoldKey.currentState?.closeDrawer();
                update(() {
                  folder = entry.key;
                  search = '';
                });
              },
            ),
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(app.text('搜索', 'Search')),
            onTap: () {
              scaffoldKey.currentState?.closeDrawer();
              searchNotes();
            },
          ),
          ListTile(
            key: const ValueKey('notes-menu-categories'),
            leading: const Icon(Icons.folder_outlined),
            title: Text(app.text('笔记分类', 'Note categories')),
            selected: category != null,
            onTap: () {
              scaffoldKey.currentState?.closeDrawer();
              openCategories();
            },
          ),
          const Divider(),
          SwitchListTile(
            title: Text(app.text('网格显示', 'Grid view')),
            value: grid,
            secondary: const Icon(Icons.grid_view),
            onChanged: (value) => setState(() => grid = value),
          ),
          ListTile(
            leading: const Icon(Icons.sort),
            title: Text(app.text('笔记排序', 'Sort notes')),
            onTap: () {
              scaffoldKey.currentState?.closeDrawer();
              chooseSort();
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              app.text(
                app.scopeId == 'guest' ? '访客笔记仅保存在本机。' : '笔记先保存本机，联网后自动同步。',
                app.scopeId == 'guest'
                    ? 'Guest notes stay on this device.'
                    : 'Notes save locally first and sync online.',
              ),
            ),
          ),
          if (app.scopeId != 'guest')
            TextButton.icon(
              onPressed: () async {
                await app.cloud?.syncNotes();
                if (mounted) update(() {});
              },
              icon: const Icon(Icons.sync),
              label: Text(
                app.text(
                  switch (app.cloud?.client?.auth.currentSession == null
                      ? 'waiting_login'
                      : app.cloud?.notesWorker?.status) {
                    'synced' => '笔记已同步 · 点击刷新',
                    'syncing' => '正在同步笔记…',
                    'waiting_login' => '请登录后同步',
                    'waiting_network' => '等待网络 · 本地已保存',
                    'server_denied' => '服务器拒绝写入 · 点击重试',
                    'invalid_data' => '数据格式错误 · 点击重试',
                    'local_saved' => '本地已保存',
                    'failed' => '同步失败，已保存在本机 · 点击重试',
                    _ => '等待同步 · 点击重试',
                  },
                  switch (app.cloud?.client?.auth.currentSession == null
                      ? 'waiting_login'
                      : app.cloud?.notesWorker?.status) {
                    'synced' => 'Notes synced · Refresh',
                    'syncing' => 'Syncing notes…',
                    'waiting_login' => 'Sign in to sync',
                    'waiting_network' => 'Waiting for network · Saved locally',
                    'server_denied' => 'Server denied the write · Retry',
                    'invalid_data' => 'Invalid data · Retry',
                    'local_saved' => 'Saved locally',
                    'failed' => 'Sync failed; saved locally · Retry',
                    _ => 'Waiting to sync · Retry',
                  },
                ),
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: scaffoldKey,
    drawer: notesMenu(),
    appBar: AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 4,
      title: selecting
          ? Text(
              app.text(
                '已选择 ${selected.length} 项',
                '${selected.length} selected',
              ),
            )
          : AdaptiveActionBar(
              maxFontSize: 22,
              menuIndex: 0,
              actions: [
                BarAction(app.text('分类', 'Categories'), openCategories),
                BarAction(
                  app.text('所有笔记', 'All notes'),
                  () => update(() => folder = 'active'),
                ),
              ],
              menu: IconButton(
                tooltip: app.text('笔记菜单', 'Notes menu'),
                icon: const Icon(Icons.menu),
                onPressed: () => scaffoldKey.currentState?.openDrawer(),
              ),
            ),
      actions: selecting
          ? [
              IconButton(
                tooltip: app.text('全选 / 取消全选', 'Select all / Clear all'),
                icon: const Icon(Icons.select_all),
                onPressed: selectAllCurrent,
              ),
              PopupMenuButton<String>(
                tooltip: app.text('批量操作', 'Bulk actions'),
                onSelected: bulkChange,
                itemBuilder: (_) => [
                  if (selected.length != 1 || !singleSelectedHas('isPinned'))
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(app.text('置顶', 'Pin')),
                    ),
                  if (selected.length != 1 || singleSelectedHas('isPinned'))
                    PopupMenuItem(
                      value: 'unpin',
                      child: Text(app.text('取消置顶', 'Unpin')),
                    ),
                  if (selected.length != 1 || !singleSelectedHas('isFavorite'))
                    PopupMenuItem(
                      value: 'favorite',
                      child: Text(app.text('收藏', 'Favorite')),
                    ),
                  if (selected.length != 1 || singleSelectedHas('isFavorite'))
                    PopupMenuItem(
                      value: 'unfavorite',
                      child: Text(app.text('取消收藏', 'Unfavorite')),
                    ),
                  if (selected.length != 1 || !singleSelectedHas('isArchived'))
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(app.text('归档', 'Archive')),
                    ),
                  if (selected.length != 1 || singleSelectedHas('isArchived'))
                    PopupMenuItem(
                      value: 'unarchive',
                      child: Text(app.text('取消归档', 'Unarchive')),
                    ),
                  PopupMenuItem(
                    value: 'category_add',
                    child: Text(app.text('添加到笔记本', 'Add to notebooks')),
                  ),
                  PopupMenuItem(
                    value: 'category',
                    child: Text(app.text('移动到笔记本', 'Move to notebook')),
                  ),
                  PopupMenuItem(
                    value: 'trash',
                    child: Text(app.text('移入回收站', 'Move to trash')),
                  ),
                ],
              ),
              IconButton(
                tooltip: app.text('取消', 'Cancel'),
                icon: const Icon(Icons.close),
                onPressed: () => setState(selected.clear),
              ),
            ]
          : [
              IconButton(
                tooltip: app.text('搜索笔记与文章', 'Search notes and articles'),
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteSearchPage(app: app),
                  ),
                ),
              ),
            ],
      bottom: search.isEmpty && category == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (category != null)
                      InputChip(
                        key: const ValueKey('notes-category-chip'),
                        avatar: const Icon(Icons.folder_outlined, size: 18),
                        label: Text(
                          category!.isEmpty ? '未分类' : category!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: openCategories,
                        onDeleted: () => update(() => folder = 'active'),
                      ),
                    if (search.isNotEmpty)
                      InputChip(
                        label: Text(
                          '${app.text('搜索', 'Search')}: $search',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: searchNotes,
                        onDeleted: () => update(() => search = ''),
                      ),
                  ],
                ),
              ),
            ),
    ),
    body: folder == 'published'
        ? PublishedNotesPage(app: app, embedded: true, search: search)
        : FutureBuilder<List<Map<String, Object?>>>(
            future: rows,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: TextButton(
                    onPressed: () => update(() {}),
                    child: Text(app.text('加载失败，点击重试', 'Could not load. Retry')),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final notes = snapshot.data!;
              if (notes.isEmpty) {
                return Center(child: Text(app.text('暂无笔记', 'No notes')));
              }
              Widget card(int index) {
                final n = notes[index];
                final tile = ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  onTap: selecting
                      ? () => select(n)
                      : folder == 'trash'
                      ? null
                      : () => edit(n, notes, index),
                  onLongPress: () => quickMenu(n),
                  title: NotePinnedTitle(
                    pinned: n['isPinned'] == 1,
                    label: app.text('已置顶', 'Pinned'),
                    child: Text(
                      '${n['conflictOf'] == null ? '' : app.text('【冲突副本】', '[Conflict copy] ')}${noteSummary(n)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize:
                            (Theme.of(
                                  context,
                                ).textTheme.titleMedium?.fontSize ??
                                16) *
                            1.1,
                      ),
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        NoteRichContent.plainText(
                          n['body'] as String? ?? '',
                        ).trim().split('\n').skip(1).join(' ').trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize:
                              (Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.fontSize ??
                                  14) *
                              1.06,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${MaterialLocalizations.of(context).formatShortDate(DateTime.parse(n['updatedAt'] as String).toLocal())} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.parse(n['updatedAt'] as String).toLocal()), alwaysUse24HourFormat: true)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (n['isFavorite'] == 1 ||
                          n['isFavorite2'] == 1 ||
                          n['displaySync'] == 'failed')
                        Wrap(
                          spacing: 8,
                          children: [
                            if (n['isFavorite'] == 1)
                              const Icon(Icons.star_outline, size: 14),
                            if (n['isFavorite2'] == 1) const Text('2★'),
                            if (n['displaySync'] == 'failed')
                              Text(
                                app.text(
                                  '同步失败 · 菜单中重试',
                                  'Sync failed · Retry in menu',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                    ],
                  ),
                  trailing: selecting
                      ? Checkbox(
                          value: selected.contains(n['id']),
                          onChanged: (_) => select(n),
                        )
                      : PopupMenuButton<String>(
                          onSelected: (value) => change(n, value),
                          itemBuilder: (_) => [
                            if (folder == 'trash')
                              PopupMenuItem(
                                value: 'restore',
                                child: Text(app.text('恢复', 'Restore')),
                              )
                            else ...[
                              PopupMenuItem(
                                value: 'isPinned',
                                child: Text(
                                  app.text(
                                    n['isPinned'] == 1 ? '取消置顶' : '置顶',
                                    n['isPinned'] == 1 ? 'Unpin' : 'Pin',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'isFavorite',
                                child: Text(
                                  app.text(
                                    n['isFavorite'] == 1 ? '取消收藏' : '收藏',
                                    n['isFavorite'] == 1
                                        ? 'Unfavorite'
                                        : 'Favorite',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'isArchived',
                                child: Text(
                                  app.text(
                                    n['isArchived'] == 1 ? '取消归档' : '归档',
                                    n['isArchived'] == 1
                                        ? 'Unarchive'
                                        : 'Archive',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'category',
                                child: Text(
                                  app.text('加入 / 移动到分类', 'Move to category'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'trash',
                                child: Text(app.text('移入回收站', 'Move to trash')),
                              ),
                            ],
                          ],
                        ),
                );
                if (grid) {
                  return NoteGridCard(
                    title: (tile.title! as NotePinnedTitle).child,
                    summary: NoteRichContent.plainText(
                      n['body'] as String? ?? '',
                    ).trim().split('\n').skip(1).join(' ').trim(),
                    date: MaterialLocalizations.of(context).formatShortDate(
                      DateTime.parse(n['updatedAt'] as String).toLocal(),
                    ),
                    menu: tile.trailing!,
                    onTap: tile.onTap,
                    onLongPress: tile.onLongPress,
                    selected: selected.contains(n['id']),
                    pinned: n['isPinned'] == 1,
                    favorite: n['isFavorite'] == 1,
                    favorite2: n['isFavorite2'] == 1,
                    failed: n['displaySync'] == 'failed',
                  );
                }
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  child: tile,
                );
              }

              if (grid) {
                return NoteGrid(
                  count: notes.length,
                  builder: (_, i) => card(i),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 100),
                itemCount: notes.length,
                itemBuilder: (_, i) => card(i),
              );
            },
          ),
    floatingActionButton: folder == 'published'
        ? null
        : FloatingActionButton(
            heroTag: 'new-note',
            onPressed: () => edit(),
            tooltip: app.text('新建笔记', 'New note'),
            child: const Icon(Icons.edit_outlined),
          ),
  );
}

class NoteEditor extends StatefulWidget {
  final AppController app;
  final NotesRepository repository;
  final Map<String, Object?>? note;

  /// The source list this note was opened from (its current sort/filter
  /// order) plus this note's position in it, so left/right swipe can move
  /// to the adjacent note in that same order. Null when opened without a
  /// list context (e.g. a brand-new note), which disables the gesture.
  final List<Map<String, Object?>>? siblings;
  final int? siblingIndex;
  const NoteEditor({
    super.key,
    required this.app,
    required this.repository,
    this.note,
    this.siblings,
    this.siblingIndex,
  });
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  late final quill.QuillController editor;
  final focusNode = FocusNode();
  final readerEditorKey = GlobalKey<quill.EditorState>();
  final readerViewportKey = GlobalKey();
  bool openingReader = false;
  late Map<String, Object?> saved;
  Timer? timer;
  StreamSubscription? documentChanges;
  Future<void>? saving;
  int generation = 0, persisted = 0;
  String draftBody = '';
  bool exiting = false, promoting = false;
  String? error;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    saved = {...?widget.note};
    editor = quill.QuillController(
      document: NoteRichContent.documentFromBody(
        saved['body'] as String? ?? '',
      ),
      selection: const TextSelection.collapsed(offset: 0),
    );
    documentChanges = editor.document.changes.listen((_) => changed());
    draftBody = NoteRichContent.encode(editor.document);
    WidgetsBinding.instance.addObserver(this);
    if (widget.note == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusNode.requestFocus();
      });
    }
  }

  void changed() {
    // The Quill controller also notifies when only the selection/cursor moves.
    // Rebuilding the whole editor for those notifications can make Android
    // input appear stuck, especially on MIUI devices.  Save and refresh only
    // when the document itself has changed.
    generation++;
    if (!promoting && editor.document.length > 100000) {
      promoting = true;
      scheduleMicrotask(promoteLargeNote);
    }
    error = null;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 1200), save);
  }

  Future<void> promoteLargeNote() async {
    if (!mounted) return;
    focusNode.unfocus();
    setState(() {});
    await save();
    if (!mounted) return;
    if (error != null) {
      setState(() => promoting = false);
      return;
    }
    exiting = true;
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LargeNoteEditor(
          app: app,
          repository: widget.repository,
          note: saved,
        ),
      ),
    );
  }

  Future<void> save() async {
    timer?.cancel();
    if (persisted != generation) {
      draftBody = NoteRichContent.encode(editor.document);
    }
    if (saving != null) {
      await saving;
      if (persisted == generation || error != null) return;
    }
    if (persisted == generation) return;
    final task = _write();
    saving = task;
    await task;
    saving = null;
  }

  Future<void> _write() async {
    while (persisted < generation) {
      final current = generation;
      draftBody = NoteRichContent.encode(editor.document);
      try {
        saved = await widget.repository.save({
          ...saved,
          'title': saved['title'] ?? '',
          'body': draftBody,
        });
        SyncDiagnostics.record('note_local_saved', {
          'user_id': app.scopeId,
          'note_id': saved['id'],
          'sync_status': 'pending',
        });
        persisted = current;
        error = null;
      } on NoteConflict {
        error = app.text(
          '笔记已被修改，文字仍保留在编辑器中。请复制正文后重新打开。',
          'The note changed elsewhere. Your text is retained here; copy it before reopening.',
        );
        break;
      } catch (_) {
        error = app.text(
          '保存失败，内容仍保留在此页面，请重试。',
          'Save failed. Your text is retained here. Please retry.',
        );
        break;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> leave() async {
    await save();
    if (mounted && persisted == generation) {
      setState(() => exiting = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  void handleSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 200) return;
    unawaited(switchNote(velocity < 0 ? 1 : -1));
  }

  // Saves the current note (same path as the Done button/back gesture)
  // before ever navigating away, so a swipe can never lose an edit. Reuses
  // the caller's own list order/scope (category, favorites, search, ...)
  // instead of re-querying, so switching stays within it.
  Future<void> switchNote(int direction) async {
    final siblings = widget.siblings;
    final index = widget.siblingIndex;
    if (siblings == null || index == null) return;
    final target = index + direction;
    if (target < 0 || target >= siblings.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              target < 0
                  ? app.text('已经是第一篇', 'This is the first note')
                  : app.text('已经是最后一篇', 'This is the last note'),
            ),
          ),
        );
      }
      return;
    }
    await save();
    if (!mounted || error != null) return;
    final next = await widget.repository.get(siblings[target]['id'] as String);
    if (!mounted) return;
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => (next['body'] as String? ?? '').length > 100000
            ? LargeNoteEditor(
                app: app,
                repository: widget.repository,
                note: next,
                siblings: siblings,
                siblingIndex: target,
              )
            : NoteEditor(
                app: app,
                repository: widget.repository,
                note: next,
                siblings: siblings,
                siblingIndex: target,
              ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(save());
  }

  @override
  void dispose() {
    timer?.cancel();
    unawaited(save());
    WidgetsBinding.instance.removeObserver(this);
    documentChanges?.cancel();
    editor.dispose();
    focusNode.dispose();
    super.dispose();
  }

  Future<void> copyText() async {
    await Clipboard.setData(
      ClipboardData(text: editor.document.toPlainText().trimRight()),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(app.text('正文已复制', 'Text copied'))));
    }
  }

  Future<void> shareText() async {
    try {
      await const MethodChannel(
        'org.huideng.counter/notes',
      ).invokeMethod('shareText', editor.document.toPlainText().trimRight());
    } on MissingPluginException {
      await copyText();
    }
  }

  bool exporting = false;
  Future<void> exportNote(String format) async {
    if (exporting) return;
    exporting = true;
    try {
      final ops = editor.document.toDelta().toJson();
      final bytes = format == 'pdf'
          ? await NoteExport.pdf(ops)
          : Uint8List.fromList(
              utf8.encode(
                format == 'md'
                    ? NoteExport.markdown(ops)
                    : NoteExport.plain(ops),
              ),
            );
      final path = await FilePicker.platform.saveFile(
        dialogTitle: app.text('导出笔记', 'Export note'),
        fileName: '笔记_${DateTime.now().millisecondsSinceEpoch}.$format',
        type: FileType.custom,
        allowedExtensions: [format],
        bytes: bytes,
      );
      if (path == null) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(app.text('笔记已导出', 'Note exported'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(app.text('导出失败，请重试：$e', 'Export failed: $e'))),
        );
      }
    } finally {
      exporting = false;
    }
  }

  Future<void> insertImage() async {
    final selection = editor.selection;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        withData: true,
      );
      if (result == null || !mounted) return;
      final bytes = result.files.single.bytes;
      if (bytes == null || bytes.length > 5 * 1024 * 1024) {
        throw const FormatException('Image too large');
      }
      final offset = selection.isValid
          ? selection.start
          : editor.document.length - 1;
      // Keep image bytes in the existing body so offline save, backup and sync
      // all retain the image, rather than a temporary device file path.
      editor.replaceText(
        offset,
        selection.isValid ? selection.end - offset : 0,
        quill.BlockEmbed.image(
          'data:image/${result.files.single.extension == 'jpg' ? 'jpeg' : result.files.single.extension};base64,${base64Encode(bytes)}',
        ),
        TextSelection.collapsed(offset: offset + 1),
      );
      focusNode.requestFocus();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              app.text('无法插入图片，请选择不超过5MB的图片。', 'Choose an image up to 5 MB.'),
            ),
          ),
        );
      }
    }
  }

  Future<void> readNote() async {
    if (openingReader) return;
    openingReader = true;
    try {
      final documentOffset = visibleNoteOffset(
        readerEditorKey,
        readerViewportKey,
      );
      focusNode.unfocus();
      await save();
      if (!mounted || error != null) return;
      if (saved['id'] == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先输入并保存笔记正文')));
        return;
      }
      await openNoteReader(
        context,
        app: app,
        body: NoteRichContent.encode(editor.document),
        noteId: saved['id'] as String,
        scope: app.scopeId,
        title: saved['title'] as String? ?? '',
        documentOffset: documentOffset,
      );
      final latest = await widget.repository.get(saved['id'] as String);
      if (!mounted) return;
      if (latest['body'] == saved['body']) {
        setState(() => saved = latest);
        if (latest['deletedAt'] != null) await leave();
      }
    } finally {
      openingReader = false;
    }
  }

  Future<void> more([String? chosen]) async {
    final action =
        chosen ??
        await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              key: const ValueKey('note-more-scroll'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text('排版'),
                    leading: const Icon(Icons.format_size),
                    onTap: () => Navigator.pop(context, 'typography'),
                  ),
                  ListTile(
                    title: const Text('阅读模式'),
                    leading: const Icon(Icons.chrome_reader_mode_outlined),
                    onTap: () => Navigator.pop(context, 'reader'),
                  ),
                  ListTile(
                    title: const Text('其他方式分享'),
                    leading: const Icon(Icons.share_outlined),
                    onTap: () => Navigator.pop(context, 'system_share'),
                  ),
                  ListTile(
                    title: Text(app.text('发布到红书', 'Publish to Hongshu')),
                    leading: const Icon(Icons.article_outlined),
                    onTap: () => Navigator.pop(context, 'redbook'),
                  ),
                  ListTile(
                    title: Text(app.text('分享到聊天', 'Share to chat')),
                    leading: const Icon(Icons.chat_bubble_outline),
                    onTap: () => Navigator.pop(context, 'chat'),
                  ),
                  ListTile(
                    key: const ValueKey('note-more-category'),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(app.text('加入 / 移动到分类', 'Move to category')),
                    subtitle: Text(
                      NotesRepository.categoryOf(saved).isEmpty
                          ? '当前：未分类'
                          : '当前：${NotesRepository.categoryOf(saved)}',
                    ),
                    onTap: () => Navigator.pop(context, 'category'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: Text(app.text('置顶 / 取消置顶', 'Pin / unpin')),
                    onTap: () => Navigator.pop(context, 'pin'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.star_outline),
                    title: Text(app.text('收藏 / 取消收藏', 'Favorite / unfavorite')),
                    onTap: () => Navigator.pop(context, 'favorite'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: Text(app.text('归档 / 取消归档', 'Archive / unarchive')),
                    onTap: () => Navigator.pop(context, 'archive'),
                  ),
                  for (final format in ['txt', 'pdf', 'md'])
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: Text(
                        '${app.text('导出', 'Export')} ${format == 'md' ? 'Markdown' : format.toUpperCase()}',
                      ),
                      subtitle: format == 'pdf'
                          ? Text(
                              app.text(
                                '离线分页图片版，文字不可选中复制',
                                'Offline image PDF; text is not selectable',
                              ),
                            )
                          : null,
                      onTap: () => Navigator.pop(context, 'export_$format'),
                    ),
                  ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: Text(app.text('复制纯文本', 'Copy plain text')),
                    onTap: () => Navigator.pop(context, 'copy'),
                  ),
                ],
              ),
            ),
          ),
        );
    if (action == 'typography') {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NoteTypographyPage(scope: app.scopeId),
        ),
      );
      return;
    }
    if (action == 'reader') return readNote();
    if (action == 'system_share') return shareText();
    if (action != null && action.startsWith('export_')) {
      return exportNote(action.substring(7));
    }
    if (action == 'chat') {
      if (!mounted) return;
      return shareTextToChat(
        context,
        app,
        editor.document.toPlainText().trimRight(),
      );
    }
    if (action == 'redbook') {
      await save();
      if (!mounted || error != null) return;
      final client = app.cloud?.client;
      if (client == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ForumComposePage(
            app: app,
            repository: ForumRepository(
              ForumRemote(client),
              HomeMessageCache(cacheKey: 'forum_feed'),
            ),
            categories: forumCategories,
            initialTitle: saved['title'] as String? ?? '',
            initialBody: NoteRichContent.encode(editor.document),
            sourceNoteId: saved['id'] as String?,
          ),
        ),
      );
      return;
    }
    if (action == 'copy') return copyText();
    if (action == null) return;
    await save();
    if (!mounted || error != null) return;
    if (action == 'category') {
      if (saved['id'] == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先输入并保存笔记正文')));
        return;
      }
      final chosen = await pickNoteCategory(
        context,
        app,
        widget.repository,
        current: NotesRepository.categoryOf(saved),
      );
      if (chosen == null || !mounted) return;
      saved = await widget.repository.save({
        ...saved,
        'source_meta': NotesRepository.withCategory(
          saved['source_meta'],
          chosen,
        ),
        'body': draftBody,
      }, touch: false);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已移到“${chosen.isEmpty ? '未分类' : chosen}”')),
      );
      return;
    }
    final field = switch (action) {
      'pin' => 'isPinned',
      'favorite' => 'isFavorite',
      'favorite2' => 'isFavorite2',
      _ => 'isArchived',
    };
    saved = await widget.repository.save({
      ...saved,
      field: saved[field] == 1 ? 0 : 1,
      'body': draftBody,
    });
    if (mounted) setState(() {});
  }

  Widget toolbar(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SizedBox(
      height: 44,
      child: quill.QuillSimpleToolbar(
        controller: editor,
        config: quill.QuillSimpleToolbarConfig(
          toolbarSectionSpacing: 0,
          buttonOptions: quill.QuillSimpleToolbarButtonOptions(
            base: const quill.QuillToolbarBaseButtonOptions(
              iconSize: 18,
              iconButtonFactor: 1.5,
              iconTheme: quill.QuillIconTheme(
                iconButtonSelectedData: quill.IconButtonData(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                    maxHeight: 44,
                  ),
                  style: ButtonStyle(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                iconButtonUnselectedData: quill.IconButtonData(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                    maxHeight: 44,
                  ),
                  style: ButtonStyle(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
            fontSize: quill.QuillToolbarFontSizeButtonOptions(
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              defaultDisplayText: app.text('字号', 'Size'),
            ),
          ),
          customButtons: [
            quill.QuillToolbarCustomButtonOptions(
              icon: const Icon(Icons.image_outlined, size: 27),
              tooltip: app.text('插入图片', 'Insert image'),
              onPressed: insertImage,
            ),
          ],
          multiRowsDisplay: false,
          showDividers: false,
          showFontFamily: false,
          showFontSize: true,
          showBoldButton: true,
          showItalicButton: true,
          showUnderLineButton: true,
          showStrikeThrough: true,
          showColorButton: true,
          showBackgroundColorButton: true,
          showInlineCode: false,
          showClearFormat: true,
          showAlignmentButtons: false,
          showHeaderStyle: false,
          showListNumbers: true,
          showListBullets: true,
          showListCheck: true,
          showCodeBlock: false,
          showQuote: false,
          showIndent: true,
          showLink: true,
          showUndo: true,
          showRedo: true,
          showDirection: false,
          showSearchButton: false,
          showSubscript: false,
          showSuperscript: false,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: exiting,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) leave();
    },
    child: Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight: 52,
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        title: AdaptiveActionBar(
          menuIndex: 1,
          actions: [
            BarAction(
              app.text('阅读模式', 'Reading mode'),
              readNote,
              icon: Icons.chrome_reader_mode_outlined,
              visualScale: .85,
            ),
            // Completion is a normal text action, not a warning color.
            BarAction(app.text('完成', 'Done'), leave, visualScale: .85),
          ],
          menu: IconButton(
            tooltip: app.text('更多', 'More'),
            onPressed: more,
            icon: Icon(
              Icons.more_horiz,
              size: 24 * 1.12,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
      body: promoting
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: widget.siblings == null ? null : handleSwipe,
              child: Column(
                children: [
                  Expanded(
                    child: SharedRichEditor(
                      key: readerViewportKey,
                      readingScope: app.scopeId,
                      controller: editor,
                      focusNode: focusNode,
                      config: quill.QuillEditorConfig(
                        editorKey: readerEditorKey,
                        autoFocus: widget.note == null,
                        expands: true,
                        embedBuilders: [NoteImageBuilder()],
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                        placeholder: app.text('开始书写…', 'Start writing…'),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        toolbar(context),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              error ??
                                  app.text(
                                    '${editor.document.toPlainText().trim().runes.length} 字符 · ${persisted == generation ? '已本地保存' : '正在保存'}',
                                    '${editor.document.toPlainText().trim().runes.length} characters · ${persisted == generation ? 'Saved locally' : 'Saving'}',
                                  ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    height: 1.2,
                                    color: error == null
                                        ? null
                                        : Theme.of(context).colorScheme.error,
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    ),
  );
}
