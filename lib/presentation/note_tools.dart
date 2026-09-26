import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import 'note_categories_page.dart';
import 'note_reader_page.dart';

/// Explicit metadata operations; the reader never writes its body snapshot back.
Future<bool> runNoteTool(
  BuildContext context,
  AppController app,
  String id,
  String action,
) async {
  final repository = NotesRepository(
    (app.repository as SqliteCounterRepository).db,
  );
  try {
    final row = await repository.get(id);
    if (action == 'history') {
      final revisions = await repository.db.query(
        'note_revisions',
        columns: ['id', 'createdAt'],
        where: 'noteId=?',
        whereArgs: [id],
        orderBy: 'createdAt DESC',
        limit: 200,
      );
      if (!context.mounted) return false;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (pageContext) => Scaffold(
            appBar: AppBar(title: const Text('版本历史（本机）')),
            body: ListView.builder(
              itemCount: revisions.length,
              itemBuilder: (_, index) {
                final revision = revisions[index];
                return ListTile(
                  title: Text(revision['createdAt'].toString()),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final stored = await repository.db.query(
                      'note_revisions',
                      columns: ['payload'],
                      where: 'id=?',
                      whereArgs: [revision['id']],
                    );
                    final data =
                        jsonDecode(stored.single['payload'] as String) as Map;
                    if (!pageContext.mounted) return;
                    await Navigator.push(
                      pageContext,
                      MaterialPageRoute(
                        builder: (_) => NoteReaderPage(
                          storedNote: false,
                          app: app,
                          body: data['body'] as String,
                          title: data['title'] as String? ?? '',
                          noteId: 'revision-${revision['id']}',
                          scope: app.scopeId,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      return false;
    }
    if (action == 'trash') {
      if (!context.mounted) return false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('移至回收站？'),
          content: const Text('笔记可以从回收站恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('移至回收站'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
      await repository.save({
        ...row,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    }
    if (action == 'move_space' || action == 'copy_space') {
      if (!context.mounted) return false;
      final space = await pickNoteCategory(
        context,
        app,
        repository,
        current: action == 'move_space'
            ? NotesRepository.categoryOf(row)
            : null,
        title: action == 'move_space' ? '加入 / 移动到分类' : '复制到分类',
      );
      if (space == null) return false;
      if (action == 'move_space') {
        await repository.setCategory([id], space);
      } else {
        final copy = {
          ...row,
          'source_meta': NotesRepository.withCategory(row['source_meta'], space),
        };
        copy.remove('id');
        copy.remove('version');
        await repository.save(copy);
      }
      if (context.mounted) {
        final name = space.isEmpty ? '未分类' : space;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              action == 'move_space' ? '已移到“$name”' : '已复制到“$name”',
            ),
          ),
        );
      }
      return false;
    }
    if (action == 'duplicate') {
      await repository.save({
        'title': row['title'],
        'body': row['body'],
        'source_post_id': row['source_post_id'],
        'source_meta': row['source_meta'],
      });
    } else if (action == 'pin' || action == 'quick') {
      final field = action == 'pin' ? 'isPinned' : 'isFavorite';
      await repository.save({...row, field: row[field] == 1 ? 0 : 1});
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(action == 'duplicate' ? '已创建独立副本。' : '已保存在本机，联网后同步。'),
        ),
      );
    }
  } catch (e) {
    debugPrint('Note tool $action: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作未完成，原笔记保留。请重试。')));
    }
  }
  return false;
}
