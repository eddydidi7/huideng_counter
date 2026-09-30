import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/data/repositories/backup_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'quick access and additive notebooks preserve content and independent flags',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      try {
        final repo = NotesRepository(db);
        final note = await repo.save({
          'body': '原始正文',
          'isPinned': 1,
          'isFavorite': 1,
          'source_meta': '{"origin":"preserve"}',
        });
        final id = note['id'] as String;
        await repo.setQuickAccess(id, true);
        await repo.addCategories([id], ['甲', '乙', '甲']);
        expect(NotesRepository.categoriesOf(await repo.get(id)), ['甲', '乙']);
        expect(await repo.categoryCounts(), {'甲': 1, '乙': 1});
        await repo.replaceCategory('甲', '丙');
        await repo.replaceCategory('乙', '');
        expect(NotesRepository.categoriesOf(await repo.get(id)), ['丙']);
        await repo.setQuickAccess(id, false);
        final saved = await repo.get(id);
        expect(NotesRepository.isQuickAccess(saved), isFalse);
        expect(saved['isPinned'], 1);
        expect(saved['isFavorite'], 1);
        expect(saved['body'], '原始正文');
        expect(saved['source_meta'].toString(), contains('preserve'));
        expect(saved['updatedAt'], note['updatedAt']);
      } finally {
        await db.close();
      }
    },
  );
  test(
    'notes reject stale saves; Chinese search and trash restore retain revisions',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final notes = NotesRepository(db);
      final first = await notes.save({'title': '闻思', 'body': '阿弥陀佛'});
      final second = await notes.save({...first, 'body': '今日闻思'});
      await expectLater(
        notes.save({...first, 'body': '旧版本'}),
        throwsA(isA<NoteConflict>()),
      );
      expect((await notes.list(search: '闻思')).single['body'], '今日闻思');
      final deleted = await notes.save({
        ...second,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(await notes.list(), isEmpty);
      expect(await notes.list(folder: 'trash'), hasLength(1));
      await notes.save({...deleted, 'deletedAt': null});
      expect(await notes.list(), hasLength(1));
      expect(await db.query('note_revisions'), hasLength(4));
      await db.close();
    },
  );
  test(
    'full backup preserves conflicting notes and importing twice is idempotent',
    () async {
      final dir = await Directory.systemTemp.createTemp('huideng_notes_test_');
      final a = await LocalDatabase.openAt('${dir.path}/a.sqlite');
      final b = await LocalDatabase.openAt('${dir.path}/b.sqlite');
      try {
        final n = await NotesRepository(a).save({'title': '课程', 'body': '版本一'});
        final backup = BackupRepository(a, Directory('${dir.path}/out'));
        final restore = BackupRepository(b, Directory('${dir.path}/in'));
        final bytes = await backup.export();
        await restore.import(bytes, restoreSettings: false);
        await NotesRepository(b).save({...n, 'body': '本机新内容'});
        await restore.import(bytes, restoreSettings: false);
        await restore.import(bytes, restoreSettings: false);
        expect(
          (await NotesRepository(b).list()).map((n) => n['body']).toSet(),
          {'版本一', '本机新内容'},
        );
        expect(await b.query('notes'), hasLength(2));
      } finally {
        await a.close();
        await b.close();
        if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
            !dir.path.contains('huideng_notes_test_')) {
          throw StateError('Unsafe path');
        }
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'v4 upgrade adds notes without changing existing project rows',
    () async {
      final dir = await Directory.systemTemp.createTemp('huideng_notes_test_');
      final path = '${dir.path}/upgrade.sqlite';
      var db = await LocalDatabase.openAt(path);
      try {
        final counter = SqliteCounterRepository(db);
        await counter.saveProject('保留计数', null);
        final session = await counter.beginSession(
          (await counter.projects()).single.id,
        );
        await counter.increment(session);
        await counter.endSession(session);
        final ledgerBefore = await db.query('count_changes');
        await db.execute('DROP TRIGGER practice_count_insert');
        await db.execute('DROP TABLE practice_links');
        await db.execute('DROP TABLE practice_outbox');
        await db.execute('DROP TABLE note_outbox');
        await db.execute('DROP TABLE note_cloud');
        await db.execute('DROP TABLE note_sync_state');
        await db.execute('DROP TABLE note_revisions');
        await db.execute('DROP TABLE notes');
        await db.setVersion(4);
        final before = await db.query('projects');
        await db.close();
        final backup = await LocalDatabase.backupBeforeUpgrade(path);
        expect(backup, isNotNull);
        expect(await File(backup!).exists(), true);
        db = await LocalDatabase.openAt(path);
        expect(await db.getVersion(), 9);
        expect(await db.query('projects'), before);
        expect(await db.query('count_changes'), ledgerBefore);
        expect(await db.query('notes'), isEmpty);
      } finally {
        await db.close();
        if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
            !dir.path.contains('huideng_notes_test_')) {
          throw StateError('Unsafe path');
        }
        await dir.delete(recursive: true);
      }
    },
  );
}
