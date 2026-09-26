import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/domain/history_range.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test('sources, corrections, exact range boundaries and tombstones', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    var time = DateTime.utc(2026, 9, 15);
    final repo = SqliteCounterRepository(db, clock: () => time);
    await repo.saveProject('Test', null);
    final id = (await repo.projects()).single.id;
    final session = await repo.beginSession(id);
    await repo.increment(session, source: CountSource.volumeUp);
    time = time.add(const Duration(microseconds: 1));
    await repo.increment(session, source: CountSource.volumeDown);
    final interval = await repo.changes(
      id,
      from: DateTime.utc(2026, 9, 15),
      until: time,
    );
    expect(interval, hasLength(1));
    expect(interval.single['source'], 'volumeUp');
    await repo.correct(id, CorrectionMode.subtract, 1, 'undo');
    await repo.correct(id, CorrectionMode.set, 8, 'target');
    final all = await repo.changes(id);
    expect(all, hasLength(4));
    expect(all.map((r) => r['source']).toSet(), {
      'volumeUp',
      'volumeDown',
      'manual_subtract',
      'manual_set',
    });
    expect(all.fold<int>(0, (sum, r) => sum + (r['delta'] as int)), 8);
    await expectLater(
      repo.correct(id, CorrectionMode.subtract, 9, ''),
      throwsRangeError,
    );
    expect(await repo.changes(id), hasLength(4));
    final first = await repo.changes(id, limit: 2);
    final second = await repo.changes(id, offset: 2, limit: 2);
    expect([...first, ...second].map((r) => r['id']).toSet(), hasLength(4));
    await repo.deleteProject(id);
    expect(await repo.changes(id), isEmpty);
    expect(await db.query('count_changes'), hasLength(4));
    await db.close();
  });

  test(
    'calendar periods use calendar dates, Monday start, inclusive custom end date',
    () {
      final now = DateTime(2026, 3, 1, 15);
      expect(
        HistoryRange.forPeriod(HistoryPeriod.yesterday, now).from,
        DateTime(2026, 2, 28),
      );
      expect(
        HistoryRange.forPeriod(HistoryPeriod.week, now).from,
        DateTime(2026, 2, 23),
      );
      expect(
        HistoryRange.forPeriod(HistoryPeriod.month, now).from,
        DateTime(2026, 3, 1),
      );
      expect(
        HistoryRange.custom(DateTime(2026, 2, 1), DateTime(2026, 2, 28)).until,
        DateTime(2026, 3, 1),
      );
    },
  );

  test(
    'queued input keeps its original occurrence day and timestamp',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final occurred = DateTime(2026, 9, 15, 23, 59, 59, 999, 999);
      final repo = SqliteCounterRepository(
        db,
        clock: () => DateTime(2026, 9, 16, 0, 0, 1),
      );
      await repo.saveProject('Queued', null);
      final id = (await repo.projects()).single.id;
      final session = await repo.beginSession(id, startedAt: occurred);
      await repo.increment(
        session,
        occurredAt: occurred,
        source: CountSource.volumeUp,
      );
      expect((await repo.projects()).single.today, 0);
      expect(
        (await repo.changes(id)).single['occurredAtMicros'],
        occurred.microsecondsSinceEpoch,
      );
      expect((await db.query('count_events')).single['localDay'], '2026-09-15');
      await db.close();
    },
  );
}
