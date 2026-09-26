import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Public content cache; kept outside all user ledgers and sync queues.
class HomeMessageCache {
  final String cacheKey;
  HomeMessageCache({this.cacheKey = 'home'});
  Future<Database> _open() async {
    final directory = await getApplicationSupportDirectory();
    return openDatabase(
      p.join(directory.path, 'public_content.sqlite'),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE content (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      ),
    );
  }

  Future<Map<String, dynamic>?> read() async {
    final db = await _open();
    final rows = await db.query(
      'content',
      where: 'id = ?',
      whereArgs: [cacheKey],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
      jsonDecode(rows.first['payload'] as String),
    );
  }

  Future<void> write(Map<String, dynamic> value) async {
    final db = await _open();
    await db.insert('content', {
      'id': cacheKey,
      'payload': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
