import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/repositories/note_categories.dart';
import '../data/repositories/notes_repository.dart';

NoteCategories noteCategoriesFor(AppController app, NotesRepository notes) =>
    NoteCategories(
      notes,
      () => app.preferences[NoteCategories.settingKey],
      (value) => app.set(NoteCategories.settingKey, value),
    );

void _message(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error is StateError ? error.message : '操作未完成，笔记未改动。请重试。'),
    ),
  );
}

Future<String?> promptCategoryName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final input = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: input,
        autofocus: true,
        maxLength: NoteCategories.maxLength,
        decoration: const InputDecoration(hintText: '例如：佛法、经论、课程'),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(c, input.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  // Allow the closing dialog animation to dispose its TextField first.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
  final name = value?.trim();
  return name == null || name.isEmpty ? null : name;
}

const _newCategory = '\u0000new';

Future<List<String>?> pickNoteCategories(
  BuildContext context,
  AppController app,
  NotesRepository notes,
) async {
  final data = await noteCategoriesFor(app, notes).load();
  if (!context.mounted) return null;
  if (data.names.isEmpty) {
    final created = await pickNoteCategory(
      context,
      app,
      notes,
      title: '添加到笔记本',
    );
    return created == null || created.isEmpty ? null : [created];
  }
  final selected = <String>{};
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxWidth: 480,
      maxHeight: MediaQuery.sizeOf(context).height * .8,
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(dense: true, title: Text('添加到笔记本')),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final name in data.names)
                    CheckboxListTile(
                      dense: true,
                      title: Text(name),
                      value: selected.contains(name),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          selected.add(name);
                        } else {
                          selected.remove(name);
                        }
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, selected.toList()),
                child: const Text('添加'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Returns the chosen category ('' = uncategorized) or null when cancelled.
Future<String?> pickNoteCategory(
  BuildContext context,
  AppController app,
  NotesRepository notes, {
  String? current,
  String title = '加入 / 移动到分类',
}) async {
  final store = noteCategoriesFor(app, notes);
  final data = await store.load();
  if (!context.mounted) return null;
  Widget? mark(String name) =>
      current == name ? const Icon(Icons.check, size: 20) : null;
  final chosen = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
    ),
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            dense: true,
            title: Text(title, style: Theme.of(c).textTheme.titleMedium),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('新建分类'),
            onTap: () => Navigator.pop(c, _newCategory),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('未分类'),
            trailing: mark(''),
            onTap: () => Navigator.pop(c, ''),
          ),
          for (final name in data.names)
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_outlined),
              title: Text(name),
              trailing: mark(name),
              onTap: () => Navigator.pop(c, name),
            ),
        ],
      ),
    ),
  );
  if (chosen != _newCategory) return chosen;
  if (!context.mounted) return null;
  final name = await promptCategoryName(context, title: '新建分类');
  if (name == null) return null;
  try {
    return await store.create(name);
  } catch (e) {
    if (context.mounted) _message(context, e);
    return null;
  }
}

/// Notebook-style category manager. Pops with the folder key to show:
/// 'active', 'uncategorized' or 'notebook:' followed by the category name.
class NoteCategoriesPage extends StatefulWidget {
  final AppController app;
  final NotesRepository notes;
  final String current;
  const NoteCategoriesPage({
    super.key,
    required this.app,
    required this.notes,
    this.current = 'active',
  });
  @override
  State<NoteCategoriesPage> createState() => _NoteCategoriesPageState();
}

class _NoteCategoriesPageState extends State<NoteCategoriesPage> {
  late final store = noteCategoriesFor(widget.app, widget.notes);
  List<String> names = [];
  Map<String, int> counts = {};
  bool loading = true, busy = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final data = await store.load();
    if (!mounted) return;
    setState(() {
      names = data.names;
      counts = data.counts;
      loading = false;
    });
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _message(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
      await reload();
    }
  }

  Future<void> create() async {
    final name = await promptCategoryName(context, title: '新建分类');
    if (name != null) await run(() => store.create(name));
  }

  Future<void> rename(String from) async {
    final name = await promptCategoryName(
      context,
      title: '重命名分类',
      initial: from,
    );
    if (name != null && name != from) await run(() => store.rename(from, name));
  }

  Future<void> delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除分类“$name”？'),
        content: const Text('删除分类不会删除其中的笔记，笔记将移至未分类。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除分类'),
          ),
        ],
      ),
    );
    if (confirmed == true) await run(() => store.delete(name));
  }

  Widget tile({
    Key? key,
    required IconData icon,
    required String title,
    required int count,
    required String folder,
    Widget? leading,
    Widget? menu,
  }) => ListTile(
    key: key,
    dense: true,
    visualDensity: VisualDensity.compact,
    leading: leading ?? Icon(icon),
    title: Text(title, style: Theme.of(context).textTheme.titleMedium),
    selected: widget.current == folder,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$count', style: Theme.of(context).textTheme.bodyMedium),
        ?menu,
      ],
    ),
    onTap: busy ? null : () => Navigator.pop(context, folder),
  );

  @override
  Widget build(BuildContext context) {
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记分类'),
        bottom: busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 24),
              header: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('note-category-create'),
                        onPressed: busy ? null : create,
                        icon: const Icon(Icons.add),
                        label: const Text('新建分类'),
                      ),
                    ),
                  ),
                  tile(
                    icon: Icons.notes,
                    title: '全部笔记',
                    count: total,
                    folder: 'active',
                  ),
                  tile(
                    icon: Icons.inbox_outlined,
                    title: '未分类',
                    count: counts[''] ?? 0,
                    folder: 'uncategorized',
                  ),
                  const Divider(height: 1),
                ],
              ),
              footer: names.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('还没有分类。点“新建分类”添加，例如：佛法、经论、课程。'),
                    )
                  : null,
              itemCount: names.length,
              onReorderItem: (from, to) {
                if (busy) return;
                setState(() => names.insert(to, names.removeAt(from)));
                run(() => store.reorder([...names]));
              },
              itemBuilder: (context, index) {
                final name = names[index];
                return tile(
                  key: ValueKey('note-category-$name'),
                  icon: Icons.folder_outlined,
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_indicator),
                  ),
                  title: name,
                  count: counts[name] ?? 0,
                  folder: 'notebook:$name',
                  menu: PopupMenuButton<String>(
                    enabled: !busy,
                    onSelected: (action) =>
                        action == 'rename' ? rename(name) : delete(name),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除分类')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
