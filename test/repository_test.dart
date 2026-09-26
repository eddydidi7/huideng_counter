import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/domain/models.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Database db;
  late SqliteCounterRepository repo;
  late DateTime clock;
  late String id;
  setUp(() async {
    db = await LocalDatabase.openAt(inMemoryDatabasePath);
    clock = DateTime(2026, 9, 15, 23, 59, 59);
    repo = SqliteCounterRepository(db, clock: () => clock);
    await repo.saveProject('Test', null);
    id = (await repo.projects()).single.id;
  });
  tearDown(() => db.close());

  test('rapid concurrent taps are atomic and match session history', () async {
    final session = await repo.beginSession(id);
    await Future.wait(List.generate(100, (_) => repo.increment(session)));
    await repo.endSession(session);
    final project = (await repo.projects()).single;
    expect(project.total, 100);
    expect(project.today, 100);
    final history = (await repo.history(id)).single;
    expect(history['delta'], 100);
    expect(history['afterValue'], 100);
    expect(history['endAt'], isNotNull);
  });

  test('midnight splits daily counts without splitting total', () async {
    final session = await repo.beginSession(id);
    await repo.increment(session);
    clock = DateTime(2026, 9, 16, 0, 0, 1);
    await repo.increment(session);
    expect((await repo.projects()).single.today, 1);
    expect((await repo.projects()).single.total, 2);
    await repo.recoverSessions();
    expect(
      (await repo.history(id)).single['endAt'],
      clock.toUtc().toIso8601String(),
    );
    await expectLater(repo.increment(session), throwsStateError);
  });

  test(
    'corrections audit all modes and invalid decrement rolls back',
    () async {
      await repo.correct(id, CorrectionMode.add, 20, 'initial');
      await repo.correct(id, CorrectionMode.subtract, 3, 'fix');
      await repo.correct(id, CorrectionMode.set, 9, 'set');
      expect((await repo.projects()).single.total, 9);
      expect((await repo.projects()).single.today, 0);
      expect((await repo.history(id)).length, 3);
      await expectLater(
        repo.correct(id, CorrectionMode.subtract, 10, ''),
        throwsRangeError,
      );
      expect((await repo.projects()).single.total, 9);
      expect((await repo.history(id)).length, 3);
      final rows = await db.query('corrections');
      expect(rows.map((r) => r['delta']), [20, -3, -8]);
      expect(rows.map((r) => r['beforeValue']), [0, 20, 17]);
      expect(
        rows.every(
          (r) =>
              r['id'] != null &&
              r['createdAt'] != null &&
              r['syncStatus'] == 'pending',
        ),
        isTrue,
      );
    },
  );

  test('reorder and soft deletion retain tombstones for future sync', () async {
    await repo.saveProject('Second', null);
    final second = (await repo.projects()).last.id;
    await repo.reorder([second, id]);
    expect((await repo.projects()).first.id, second);
    final session = await repo.beginSession(id);
    await repo.increment(session);
    await repo.correct(id, CorrectionMode.add, 2, '');
    await repo.deleteProject(id);
    expect((await repo.projects()).length, 1);
    for (final table in [
      'projects',
      'sessions',
      'count_events',
      'corrections',
    ]) {
      final rows = await db.query(
        table,
        where: '${table == 'projects' ? 'id' : 'projectId'} = ?',
        whereArgs: [id],
      );
      expect(rows.single['deletedAt'], isNotNull);
    }
  });

  test('counts and settings survive database close and reopen', () async {
    final dir = await Directory.systemTemp.createTemp('huideng_test_');
    final path = '${dir.path}/persist.sqlite';
    final disk = await LocalDatabase.openAt(path);
    final first = SqliteCounterRepository(disk);
    await first.saveProject('Persist', null);
    final projectId = (await first.projects()).single.id;
    final sessionId = await first.beginSession(projectId);
    await first.increment(sessionId);
    await first.saveSetting('language', 'en');
    await disk.close();
    final reopened = await LocalDatabase.openAt(path);
    final second = SqliteCounterRepository(reopened);
    await second.recoverSessions();
    expect((await second.projects()).single.total, 1);
    expect((await second.settings())['language'], 'en');
    expect((await second.history(projectId)).single['endAt'], isNotNull);
    await reopened.close();
    await dir.delete(recursive: true);
  });
}
