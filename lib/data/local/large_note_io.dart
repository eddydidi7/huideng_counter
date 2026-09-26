import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';

/// Avoid Android CursorWindow's per-row limit, while keeping existing TEXT columns.
Future<String> readLargeText(
  DatabaseExecutor db,
  String table,
  String column,
  String key,
  Object id,
) async {
  final bytes = BytesBuilder(copy: false);
  for (var offset = 1; ; offset += 65536) {
    final rows = await db.rawQuery(
      'SELECT substr(CAST("$column" AS BLOB),?,65536) AS chunk FROM "$table" WHERE "$key"=?',
      [offset, id],
    );
    if (rows.isEmpty) return '';
    final part = rows.single['chunk'] as List<int>? ?? [];
    bytes.add(part);
    if (part.length < 65536) break;
  }
  final data = bytes.takeBytes();
  return data.length < 100000
      ? utf8.decode(data)
      : compute(decodeNoteBytes, data);
}

Future<List<Map<String, Object?>>> noteRows(
  DatabaseExecutor db,
  String id,
) async {
  final columns = (await db.rawQuery(
    'PRAGMA table_info(notes)',
  )).map((r) => r['name'] as String).where((n) => n != 'body').toList();
  final rows = await db.query(
    'notes',
    columns: columns,
    where: 'id=?',
    whereArgs: [id],
  );
  if (rows.isEmpty) return [];
  return [
    {
      ...rows.single,
      'body': await readLargeText(db, 'notes', 'body', 'id', id),
    },
  ];
}

Future<List<Map<String, Object?>>> noteHistory(
  DatabaseExecutor db,
  String id,
) async {
  final rows = await db.query(
    'note_revisions',
    columns: ['id', 'noteId', 'createdAt'],
    where: 'noteId=?',
    whereArgs: [id],
    orderBy: 'createdAt,id',
  );
  return [
    for (final row in rows)
      {
        ...row,
        'payload': await readLargeText(
          db,
          'note_revisions',
          'payload',
          'id',
          row['id']!,
        ),
      },
  ];
}

String decodeNoteBytes(Uint8List bytes) => utf8.decode(bytes);
