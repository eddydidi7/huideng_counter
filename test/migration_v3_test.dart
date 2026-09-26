import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/local/migrations/migration_v2.dart';
import 'fixtures/v1_database.dart';

void main() {
  test(
    'existing v2 database is backed up and every legacy column remains identical',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('huideng_v3_');
      final path = '${directory.path}/original.sqlite';
      final v1 = await V1Database.openAt(path);
      const time = '2026-09-15T00:00:00Z';
      await v1.insert('projects', {
        'id': 'legacy-project',
        'name': '保留项目',
        'imagePath': 'original.jpg',
        'total': 0,
        'position': 0,
        'createdAt': time,
        'updatedAt': time,
        'syncStatus': 'pending',
      });
      await v1.close();
      final v2 = await openDatabase(
        path,
        version: 2,
        onUpgrade: (db, old, next) => migrateToV2(db),
      );
      final original = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'projects',
        'sessions',
        'count_events',
        'corrections',
        'settings',
        'count_changes',
      ]) {
        original[table] = await v2.query(table);
      }
      await v2.close();
      final backup = await LocalDatabase.backupBeforeUpgrade(path);
      expect(backup, contains('.v2-'));
      final saved = await openDatabase(backup!, readOnly: true);
      expect(await saved.getVersion(), 2);
      await saved.close();
      final v3 = await LocalDatabase.openAt(path);
      expect(await v3.getVersion(), 9);
      for (final entry in original.entries) {
        expect(await v3.query(entry.key), entry.value);
      }
      final device = (await v3.query('sync_scope')).single['device_id'];
      expect((await v3.query('sync_scope')).single['user_id'], isNull);
      await v3.close();
      final reopened = await LocalDatabase.openAt(path);
      expect((await reopened.query('sync_scope')).single['device_id'], device);
      await reopened.close();
      expect(await LocalDatabase.backupBeforeUpgrade(path), isNull);
      final safe = directory.absolute.path;
      if (!safe.startsWith(Directory.systemTemp.absolute.path) ||
          !directory.uri.pathSegments.any((s) => s.startsWith('huideng_v3_'))) {
        throw StateError('Unexpected test path');
      }
      await directory.delete(recursive: true);
    },
  );
}

