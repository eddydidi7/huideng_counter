import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'migrations/migration_v2.dart';
import 'migrations/migration_v3.dart';
import 'migrations/migration_v4.dart';
import 'migrations/migration_v5.dart';
import 'migrations/migration_v6.dart';
import 'migrations/migration_v7.dart';
import 'migrations/migration_v8.dart';
import 'migrations/migration_v9.dart';

class LocalDatabase {
  static Future<Database> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final path = p.join(directory.path, 'huideng.sqlite');
    await backupBeforeUpgrade(path);
    return openAt(path);
  }

  /// Called during startup before the repository or UI can open the database.
  static Future<String?> backupBeforeUpgrade(String path) async {
    if (!await File(path).exists()) return null;
    final existing = await openDatabase(path, singleInstance: false);
    var needsBackup = false;
    var oldVersion = 0;
    try {
      final version = await existing.getVersion();
      oldVersion = version;
      needsBackup = version < 9;
      if (needsBackup) {
        final result = await existing.rawQuery('PRAGMA wal_checkpoint(FULL)');
        if (result.first.values.first != 0) {
          throw StateError('Database is busy; backup postponed.');
        }
      }
    } finally {
      await existing.close();
    }
    if (!needsBackup) return null;
    final backup =
        '$path.v$oldVersion-${DateTime.now().microsecondsSinceEpoch}.backup';
    await File(path).copy(backup);
    return backup;
  }

  static Future<Database> openAt(String path) => openDatabase(
    path,
    version: 9,
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) await migrateToV2(db);
      if (oldVersion < 3) await migrateToV3(db);
      if (oldVersion < 4) await migrateToV4(db);
      if (oldVersion < 5) await migrateToV5(db);
      if (oldVersion < 6) await migrateToV6(db);
      if (oldVersion < 7) await migrateToV7(db);
      if (oldVersion < 8) await migrateToV8(db);
      if (oldVersion < 9) await migrateToV9(db);
    },
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
      await migrateToV2(db);
      await migrateToV3(db);
      await migrateToV4(db);
      await migrateToV5(db);
      await migrateToV6(db);
      await migrateToV7(db);
      await migrateToV8(db);
      await migrateToV9(db);
    },
  );
}
