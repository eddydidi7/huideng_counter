// Frozen v1 schema from the pre-upgrade source snapshot.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class V1Database {
  static Future<Database> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    return openAt(p.join(directory.path, 'huideng.sqlite'));
  }

  static Future<Database> openAt(String path) => openDatabase(
    path,
    version: 1,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
      await db.rawQuery('PRAGMA journal_mode = WAL');
    },
    onCreate: (db, _) async {
      const meta =
          'createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, '
          "syncStatus TEXT NOT NULL DEFAULT 'pending', deletedAt TEXT";
      await db.execute(
        'CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
        'imagePath TEXT, total INTEGER NOT NULL DEFAULT 0 CHECK(total >= 0), '
        'position INTEGER NOT NULL, lastRecitedAt TEXT, $meta)',
      );
      await db.execute(
        'CREATE TABLE sessions (id TEXT PRIMARY KEY, '
        'projectId TEXT NOT NULL REFERENCES projects(id), startAt TEXT NOT NULL, '
        'endAt TEXT, added INTEGER NOT NULL DEFAULT 0, totalAfter INTEGER NOT NULL, $meta)',
      );
      await db.execute(
        'CREATE TABLE count_events (id TEXT PRIMARY KEY, '
        'sessionId TEXT NOT NULL REFERENCES sessions(id), '
        'projectId TEXT NOT NULL REFERENCES projects(id), occurredAt TEXT NOT NULL, '
        'localDay TEXT NOT NULL, $meta)',
      );
      await db.execute(
        'CREATE INDEX events_day ON count_events(projectId, localDay)',
      );
      await db.execute(
        'CREATE TABLE corrections (id TEXT PRIMARY KEY, '
        'projectId TEXT NOT NULL REFERENCES projects(id), occurredAt TEXT NOT NULL, '
        'beforeValue INTEGER NOT NULL, delta INTEGER NOT NULL, '
        'afterValue INTEGER NOT NULL, note TEXT, $meta)',
      );
      await db.execute(
        'CREATE TABLE settings (id TEXT PRIMARY KEY, '
        'settingKey TEXT UNIQUE NOT NULL, value TEXT NOT NULL, $meta)',
      );
    },
  );
}
