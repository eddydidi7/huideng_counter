import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Independent, versioned cache: no changes to counter or notes databases.
class ChatStore {
  final Database db;
  final String userId;
  ChatStore(this.db, this.userId);
  static Future<ChatStore> open(String userId) async {
    final directory = await getApplicationSupportDirectory();
    return openAt(p.join(directory.path, 'chat_cache.sqlite'), userId);
  }

  static Future<ChatStore> openAt(String path, String userId) async {
    final db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE chat_cache (user_id TEXT NOT NULL, cache_key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(user_id,cache_key))',
        );
        await db.execute(
          'CREATE TABLE chat_outbox (user_id TEXT NOT NULL, id TEXT NOT NULL, room_id TEXT NOT NULL, body TEXT NOT NULL, attachment TEXT, created_at TEXT NOT NULL, last_error TEXT, PRIMARY KEY(user_id,id))',
        );
      },
      onUpgrade: (db, old, next) async {
        if (old < 2) {
          await db.execute(
            'ALTER TABLE chat_outbox ADD COLUMN last_error TEXT',
          );
        }
      },
    );
    return ChatStore(db, userId);
  }

  Future<List<Map<String, dynamic>>> read(String key) async {
    final rows = await db.query(
      'chat_cache',
      where: 'user_id=? AND cache_key=?',
      whereArgs: [userId, key],
    );
    if (rows.isEmpty) return [];
    return (jsonDecode(rows.single['value'] as String) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> write(String key, List<Map<String, dynamic>> value) async {
    await db.insert('chat_cache', {
      'user_id': userId,
      'cache_key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> enqueue(
    String id,
    String room,
    String body, {
    Map<String, dynamic>? attachment,
  }) async {
    await db.insert('chat_outbox', {
      'user_id': userId,
      'id': id,
      'room_id': room,
      'body': body,
      'attachment': attachment == null ? null : jsonEncode(attachment),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> pending() async => (await db.query(
    'chat_outbox',
    where: 'user_id=?',
    whereArgs: [userId],
    orderBy: 'created_at,id',
  )).map((e) => Map<String, dynamic>.from(e)).toList();
  Future<void> acknowledged(String id) async {
    await db.delete(
      'chat_outbox',
      where: 'user_id=? AND id=?',
      whereArgs: [userId, id],
    );
  }

  Future<void> failed(String id, String? error) => db
      .update(
        'chat_outbox',
        {'last_error': error},
        where: 'user_id=? AND id=?',
        whereArgs: [userId, id],
      )
      .then((_) {});

  Future<Map<String, Map<String, dynamic>>> roomViews() async {
    final values = await db.query(
      'chat_cache',
      where: 'user_id=? AND cache_key LIKE ?',
      whereArgs: [userId, 'room_ui:%'],
    );
    return {
      for (final row in values)
        (row['cache_key'] as String).substring(8): Map<String, dynamic>.from(
          (jsonDecode(row['value'] as String) as List).first,
        ),
    };
  }

  Future<void> patchRoom(String room, Map<String, dynamic> patch) =>
      db.transaction((txn) async {
        final key = 'room_ui:$room';
        final rows = await txn.query(
          'chat_cache',
          where: 'user_id=? AND cache_key=?',
          whereArgs: [userId, key],
        );
        final previous = rows.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                (jsonDecode(rows.single['value'] as String) as List).first,
              );
        await txn.insert('chat_cache', {
          'user_id': userId,
          'cache_key': key,
          'value': jsonEncode([
            {...previous, ...patch},
          ]),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
}
