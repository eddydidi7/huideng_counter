import 'package:flutter/material.dart';
import '../data/repositories/notes_repository.dart';

typedef NoteMenuEntry = ({
  String action,
  IconData icon,
  String label,
  bool submenu,
});

List<NoteMenuEntry> noteQuickActions(
  Map<String, Object?> note, {
  bool trash = false,
}) {
  NoteMenuEntry item(
    String action,
    IconData icon,
    String label, {
    bool submenu = false,
  }) => (action: action, icon: icon, label: label, submenu: submenu);
  if (trash) {
    return [
      item('restore', Icons.restore, '恢复'),
      item('select', Icons.checklist, '选择笔记'),
    ];
  }
  return [
    item(
      'isPinned',
      Icons.push_pin_outlined,
      note['isPinned'] == 1 ? '取消置顶' : '置顶',
    ),
    item(
      'quick',
      Icons.bolt_outlined,
      NotesRepository.isQuickAccess(note) ? '取消快速访问' : '添加到快速访问',
    ),
    item(
      'isFavorite',
      Icons.star_outline,
      note['isFavorite'] == 1 ? '取消收藏' : '收藏',
    ),
    item('share', Icons.share_outlined, '分享到…', submenu: true),
    item('duplicate', Icons.copy_outlined, '创建副本'),
    item('category_add', Icons.folder_outlined, '添加到笔记本'),
    item('select', Icons.checklist, '选择笔记'),
    item(
      'isArchived',
      Icons.archive_outlined,
      note['isArchived'] == 1 ? '取消归档' : '归档',
    ),
    item('trash', Icons.delete_outline, '移至回收站'),
  ];
}

Future<String?> showNoteActionMenu(
  BuildContext context,
  List<NoteMenuEntry> actions,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  constraints: BoxConstraints(
    maxWidth: 480,
    maxHeight: MediaQuery.sizeOf(context).height * .8,
  ),
  builder: (ctx) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final entry in actions)
          ListTile(
            key: ValueKey('note-action-${entry.action}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            minLeadingWidth: 24,
            leading: Icon(entry.icon, size: 20),
            title: Text(entry.label),
            trailing: entry.submenu
                ? const Icon(Icons.chevron_right, size: 20)
                : null,
            onTap: () => Navigator.pop(ctx, entry.action),
          ),
      ],
    ),
  ),
);
