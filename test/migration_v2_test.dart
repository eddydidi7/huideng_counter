import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'fixtures/v1_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory directory;
  late String path;
  const time = '2026-09-15T01:00:00.000001Z';
  Map<String, Object?> meta(String id, {bool deleted = false}) => {
    'id': id,
    'createdAt': time,
    'updatedAt': time,
    'syncStatus': 'pending',
    'deletedAt': deleted ? time : null,
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huideng_migration_');
    path = '${directory.path}/test.sqlite';
    final db = await V1Database.openAt(path);
    for (final id in ['p1', 'p2']) {
      final deleted = id == 'p2';
      await db.insert('projects', {
        ...meta(id, deleted: deleted),
        'name': id,
        'imagePath': 'original/image.png',
        'total': deleted ? 1 : 2,
        'position': deleted ? 0 : 1,
        'lastRecitedAt': time,
      });
      await db.insert('sessions', {
        ...meta('s$id', deleted: deleted),
        'projectId': id,
        'startAt': time,
        'endAt': time,
        'added': deleted ? 1 : 3,
        'totalAfter': deleted ? 1 : 3,
      });
      for (var i = 0; i < (deleted ? 1 : 3); i++) {
        await db.insert('count_events', {
          ...meta('$id-event-$i', deleted: deleted),
          'projectId': id,
          'sessionId': 's$id',
          'occurredAt': time,
          'localDay': '2026-09-15',
        });
      }
    }
    await db.insert('corrections', {
      ...meta('c1'),
      'projectId': 'p1',
      'occurredAt': time,
      'beforeValue': 3,
      'delta': -1,
      'afterValue': 2,
      'note': 'original note',
    });
    await db.insert('settings', {
      ...meta('language'),
      'settingKey': 'language',
      'value': 'en',
    });
    await db.close();
  });
  tearDown(() async {
    final safePath = directory.absolute.path;
    if (!safePath.startsWith(Directory.systemTemp.absolute.path) ||
        !directory.uri.pathSegments.any(
          (p) => p.startsWith('huideng_migration_'),
        )) {
      throw StateError('Unexpected test directory');
    }
    await directory.delete(recursive: true);
  });

  test(
    'v1 backup and migration preserve every legacy row; reopen is idempotent',
    () async {
      final old = await openDatabase(path);
      final original = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'projects',
        'sessions',
        'count_events',
        'corrections',
        'settings',
      ]) {
        original[table] = await old.query(table, orderBy: 'id');
      }
      await old.close();
      final backup = await LocalDatabase.backupBeforeUpgrade(path);
      expect(backup, isNotNull);
      final backupDb = await openDatabase(backup!, readOnly: true);
      expect(await backupDb.getVersion(), 1);
      expect(
        await backupDb.query('projects', orderBy: 'id'),
        original['projects'],
      );
      await backupDb.close();
      final upgraded = await LocalDatabase.openAt(path);
      expect(await upgraded.getVersion(), 9);
      for (final entry in original.entries) {
        expect(await upgraded.query(entry.key, orderBy: 'id'), entry.value);
      }
      final changes = await upgraded.query('count_changes');
      expect(changes, hasLength(5));
      expect(
        changes.where((r) => r['source'] == 'legacy_unknown'),
        hasLength(4),
      );
      expect(changes.where((r) => r['deletedAt'] != null), hasLength(1));
      expect(
        changes.first['occurredAtMicros'],
        DateTime.parse(time).microsecondsSinceEpoch,
      );
      await upgraded.close();
      final reopened = await LocalDatabase.openAt(path);
      expect(await reopened.query('count_changes'), hasLength(5));
      await reopened.close();
      expect(await LocalDatabase.backupBeforeUpgrade(path), isNull);
    },
  );

  test(
    'reconciliation mismatch rolls back schema and leaves original totals',
    () async {
      final old = await openDatabase(path);
      await old.update(
        'projects',
        {'total': 99},
        where: 'id = ?',
        whereArgs: ['p1'],
      );
      await old.close();
      await expectLater(LocalDatabase.openAt(path), throwsStateError);
      final db = await openDatabase(path);
      expect(await db.getVersion(), 1);
      expect(
        (await db.query(
          'projects',
          where: 'id = ?',
          whereArgs: ['p1'],
        )).single['total'],
        99,
      );
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'count_changes'",
        ),
        isEmpty,
      );
      await db.close();
    },
  );
}

