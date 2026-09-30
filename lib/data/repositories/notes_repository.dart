import '../local/large_note_io.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../domain/content_limits.dart';

class NoteConflict implements Exception {}

class NotesRepository {
  final Database db;
  NotesRepository(this.db);

  Future<List<Map<String, Object?>>> list({
    String search = '',
    String folder = 'active',
    String sort = 'updatedAt',
    bool ascending = false,
  }) async {
    final where = folder == 'trash'
        ? 'deletedAt IS NOT NULL'
        : 'deletedAt IS NULL${folder == 'archive' ? ' AND isArchived=1' : ''}${folder == 'favorites'
              ? ' AND isFavorite=1'
              : folder == 'favorites2'
              ? ' AND isFavorite=1'
              : ''}';
    // instr treats user input literally, including % and _, and supports Chinese.
    final columns = (await db.rawQuery(
      'PRAGMA table_info(notes)',
    )).map((r) => r['name'] as String).where((n) => n != 'body').toList();
    final rows = await db.query(
      'notes',
      columns: [
        ...columns,
        'substr(body,1,2000) AS body',
        'length(body) AS bodyLength',
      ],
      where:
          '$where AND (instr(lower(title),lower(?))>0 OR instr(lower(body),lower(?))>0)',
      whereArgs: [search, search],
      orderBy:
          'isPinned DESC, ${sort == 'title'
              ? "COALESCE(NULLIF(trim(body),''),title) COLLATE NOCASE"
              : sort == 'createdAt'
              ? 'createdAt'
              : 'updatedAt'} ${ascending ? 'ASC' : 'DESC'}, id',
    );
    final copies = {
      for (final row in await db.query(
        'note_cloud',
        columns: ['note_id', 'conflict_of'],
      ))
        row['note_id']: row['conflict_of'],
    };
    final pending = {
      for (final row in await db.query(
        'note_outbox',
        columns: ['note_id', 'last_error'],
      ))
        row['note_id']: row['last_error'],
    };
    return rows
        .map(
          (row) => <String, Object?>{
            ...row,
            'body': noteListPreview(
              row['body'] as String,
              (row['bodyLength'] as num).toInt(),
            ),
            '_bodyPreview': true,
            'conflictOf': copies[row['id']],
            'displaySync': pending.containsKey(row['id'])
                ? (pending[row['id']] == null ? 'pending' : 'failed')
                : row['syncStatus'],
          },
        )
        .toList();
  }

  Future<Map<String, Object?>> get(String id) async =>
      (await noteRows(db, id)).single;

  /// Category ("notebook") lives in source_meta, which already syncs with the
  /// note itself. Empty string means uncategorized.
  static String categoryOf(Map<String, Object?> row) {
    return categoriesOf(row).firstOrNull ?? '';
  }

  static List<String> categoriesOf(Map<String, Object?> row) {
    try {
      final meta = jsonDecode(row['source_meta'] as String? ?? '{}') as Map;
      return <String>{
        if (meta['notebook'] is String &&
            (meta['notebook'] as String).trim().isNotEmpty)
          (meta['notebook'] as String).trim(),
        if (meta['notebooks'] is List)
          for (final name in meta['notebooks'] as List)
            if (name is String && name.trim().isNotEmpty) name.trim(),
      }.toList();
    } catch (_) {
      return [];
    }
  }

  static bool isQuickAccess(Map<String, Object?> row) {
    try {
      return (jsonDecode(row['source_meta'] as String? ?? '{}')
              as Map)['quick_access'] ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setQuickAccess(String id, bool enabled) async {
    final note = await get(id);
    final meta = Map<String, dynamic>.from(
      jsonDecode(note['source_meta'] as String? ?? '{}') as Map,
    );
    if (enabled) {
      meta['quick_access'] = true;
    } else {
      meta.remove('quick_access');
    }
    await save({...note, 'source_meta': jsonEncode(meta)}, touch: false);
  }

  static String withCategory(Object? sourceMeta, String category) {
    return withCategories(sourceMeta, [category]);
  }

  static String withCategories(
    Object? sourceMeta,
    Iterable<String> categories,
  ) {
    Map<String, dynamic> meta;
    try {
      meta = Map<String, dynamic>.from(
        jsonDecode(sourceMeta as String? ?? '{}') as Map,
      );
    } catch (_) {
      meta = {};
    }
    final names = categories
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    meta.remove('notebooks');
    if (names.isEmpty) {
      meta.remove('notebook');
    } else {
      meta['notebook'] = names.first;
      if (names.length > 1) meta['notebooks'] = names;
    }
    return jsonEncode(meta);
  }

  /// Live (non-trashed) note count per category; '' is uncategorized.
  Future<Map<String, int>> categoryCounts() async {
    final counts = <String, int>{};
    for (final row in await db.query(
      'notes',
      columns: ['source_meta'],
      where: 'deletedAt IS NULL',
    )) {
      final names = categoriesOf(row);
      for (final name in names.isEmpty ? [''] : names) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Includes trashed notes so a restored note never revives a deleted name.
  Future<List<String>> idsInCategory(String category) async => [
    for (final row in await db.query('notes', columns: ['id', 'source_meta']))
      if (category.isEmpty
          ? categoriesOf(row).isEmpty
          : categoriesOf(row).contains(category))
        row['id'] as String,
  ];

  /// Only the category changes; favorite, archive, pin and updatedAt are kept,
  /// so moving notes never reorders a time-sorted list.
  Future<void> setCategory(Iterable<String> ids, String category) async {
    for (final id in ids) {
      final note = await get(id);
      if (categoriesOf(note).length <= 1 &&
          categoryOf(note) == category.trim()) {
        continue;
      }
      await save({
        ...note,
        'source_meta': withCategory(note['source_meta'], category),
      }, touch: false);
    }
  }

  Future<void> addCategories(
    Iterable<String> ids,
    Iterable<String> categories,
  ) async {
    for (final id in ids) {
      final note = await get(id);
      await save({
        ...note,
        'source_meta': withCategories(note['source_meta'], [
          ...categoriesOf(note),
          ...categories,
        ]),
      }, touch: false);
    }
  }

  Future<void> replaceCategory(String from, String to) async {
    for (final id in await idsInCategory(from)) {
      final note = await get(id);
      await save({
        ...note,
        'source_meta': withCategories(
          note['source_meta'],
          categoriesOf(note).map((n) => n == from ? to : n),
        ),
      }, touch: false);
    }
  }

  Future<Map<String, Object?>> save(
    Map<String, Object?> draft, {
    bool touch = true,
  }) async {
    final preparedBody = draft['body'] as String? ?? '';
    if (preparedBody.length > 100000 && draft['_bodyPreview'] != true) {
      final count = await compute(noteCharacterCount, preparedBody);
      if (count > maxArticleContentCharacters) {
        throw StateError('单篇笔记最多500万字符，内容仍保留在编辑器中');
      }
    }
    return db.transaction((tx) async {
      final id = draft['id'] as String? ?? const Uuid().v4();
      final old = draft['_bodyPreview'] == true
          ? await noteRows(tx, id)
          : await tx.query(
              'notes',
              columns: [
                'version',
                'isFavorite2',
                'source_post_id',
                'source_meta',
                'createdAt',
                'updatedAt',
              ],
              where: 'id=?',
              whereArgs: [id],
            );
      if (old.isNotEmpty && old.single['version'] != draft['version']) {
        throw NoteConflict();
      }
      if (old.isEmpty && draft['version'] != null) throw NoteConflict();
      final now = DateTime.now().toUtc().toIso8601String();
      final row = <String, Object?>{
        'id': id,
        'title': draft['title'] ?? '',
        'body': draft['_bodyPreview'] == true && old.isNotEmpty
            ? old.single['body']
            : draft['body'] ?? '',
        'source_post_id':
            draft['source_post_id'] ??
            (old.isEmpty ? null : old.single['source_post_id']),
        'source_meta':
            draft['source_meta'] ??
            (old.isEmpty ? '{}' : old.single['source_meta']),
        'isPinned': draft['isPinned'] ?? 0,
        'isFavorite': draft['isFavorite2'] == 1 ? 1 : draft['isFavorite'] ?? 0,
        'isFavorite2': 0,
        'isArchived': draft['isArchived'] ?? 0,
        'deletedAt': draft['deletedAt'],
        'createdAt': old.isEmpty ? now : old.single['createdAt'],
        'updatedAt': touch || old.isEmpty ? now : old.single['updatedAt'],
        'version': (old.isEmpty ? 0 : old.single['version'] as int) + 1,
        'syncStatus': 'pending',
      };
      if (old.isEmpty) {
        await tx.insert('notes', row);
      } else {
        await tx.update('notes', row, where: 'id=?', whereArgs: [id]);
      }
      await tx.insert('note_revisions', {
        'id': const Uuid().v4(),
        'noteId': id,
        'payload': (row['body'] as String).length < 100000
            ? encodeNotePayload(row)
            : await compute(encodeNotePayload, row),
        'createdAt': now,
      });
      return row;
    });
  }
}

String encodeNotePayload(Map<String, Object?> row) => jsonEncode(row);
int noteCharacterCount(String body) {
  try {
    final delta = jsonDecode(body);
    if (delta is List &&
        delta.every((e) => e is Map && e.containsKey('insert'))) {
      return delta.fold<int>(
        0,
        (n, e) =>
            n +
            (e is Map && e['insert'] is String
                ? (e['insert'] as String).runes.length
                : 0),
      );
    }
  } catch (_) {}
  return articleContentCharacterCount(body);
}

// Android 8 SQLite does not guarantee the JSON1 extension. Decode only the
// bounded first text run, never load the full document just to list notes.
String noteListPreview(String prefix, int length) {
  if (length <= 2000 || !prefix.startsWith('[')) return prefix;
  final match = RegExp(r'"insert"\s*:\s*"').firstMatch(prefix);
  if (match == null) return '长笔记';
  var text = prefix.substring(match.end);
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\\') {
      i++;
      continue;
    }
    if (text[i] == '"') {
      text = text.substring(0, i);
      break;
    }
  }
  for (var trim = 0; trim < 7 && trim <= text.length; trim++) {
    try {
      return jsonDecode('"${text.substring(0, text.length - trim)}"') as String;
    } catch (_) {}
  }
  return '长笔记';
}
