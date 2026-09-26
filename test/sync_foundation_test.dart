import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/sync/local_sync_store.dart';
import 'package:huideng_counter/data/sync/ledger_merge.dart';
import 'package:huideng_counter/domain/models.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const a = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
  const b = 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb';
  late Database db;
  late SqliteCounterRepository repo;
  late LocalSyncStore sync;
  late DateTime now;
  setUp(() async {
    db = await LocalDatabase.openAt(inMemoryDatabasePath);
    repo = SqliteCounterRepository(db);
    now = DateTime.utc(2026, 9, 15);
    sync = LocalSyncStore(db, clock: () => now, random: Random(1));
  });
  tearDown(() => db.close());
  Future<Map<String, Object?>> snapshot(
    DatabaseExecutor tx,
    String kind,
    String id,
  ) async {
    if (kind == 'event') return sync.eventPayload(tx, id);
    if (kind == 'project') {
      return (await tx.query(
        'projects',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
    }
    return {'kind': kind, 'id': id};
  }

  test(
    'guest events survive; binding cannot leak or transfer accounts',
    () async {
      await repo.saveProject('Original', 'original.png');
      final p = (await repo.projects()).single.id;
      final session = await repo.beginSession(p);
      await repo.increment(session);
      await repo.correct(p, CorrectionMode.subtract, 1, 'undo');
      await repo.correct(p, CorrectionMode.set, 9, 'target');
      final before = await db.query('count_changes');
      await expectLater(
        sync.eventPayload(db, before.first['id'] as String),
        throwsStateError,
      );
      await sync.bindGuestDatabase(a);
      expect(await db.query('count_changes'), before);
      final payload = await sync.eventPayload(db, before.first['id'] as String);
      expect(payload['user_id'], a);
      expect(payload['delta'], 1);
      expect(payload['count_after'], 1);
      expect(payload['device_id'], isNotEmpty);
      expect((await db.query('event_sync')).map((r) => r['user_id']).toSet(), {
        a,
      });
      await expectLater(sync.bindGuestDatabase(b), throwsStateError);
      await expectLater(sync.next(b, snapshot), throwsStateError);
      expect((await repo.projects()).single.total, 9);
    },
  );

  test(
    'outbox is atomic, idempotent retries and stale ACK preserves newer edit',
    () async {
      await sync.bindGuestDatabase(a);
      await repo.saveProject('First', null);
      final p = (await repo.projects()).single.id;
      final job = (await sync.next(a, snapshot))!;
      expect(job.entityType, 'project');
      await sync.retry(job, 'network');
      expect(
        (await db.query(
          'sync_queue',
          where: "entity_type = 'project'",
        )).single['attempts'],
        1,
      );
      now = now.add(const Duration(hours: 1));
      final retry = (await sync.next(a, snapshot))!;
      expect(retry.requestId, job.requestId);
      expect(retry.payload, job.payload);
      await repo.saveProject('Changed', null, id: p);
      await sync.acknowledge(job, 1);
      final changed = (await sync.next(a, snapshot))!;
      expect(changed.payload['name'], 'Changed');
      expect(changed.requestId, isNot(job.requestId));
      await sync.acknowledge(changed, 2);
      expect(
        await db.query('sync_queue', where: "entity_type = 'project'"),
        isEmpty,
      );
      final session = await repo.beginSession(p);
      await repo.increment(session);
      final event = (await sync.next(a, snapshot))!;
      expect(event.entityType, 'event');
      await sync.retry(event, 'timeout');
      await repo.increment(
        session,
      ); // No connectivity needed, no total rollback.
      expect((await repo.projects()).single.total, 2);
      final pending = await db.query(
        'sync_queue',
        where: "entity_type = 'event'",
      );
      expect(pending, hasLength(2));
      await expectLater(
        repo.correct(p, CorrectionMode.subtract, 3, ''),
        throwsRangeError,
      );
      expect(
        await db.query('sync_queue', where: "entity_type = 'event'"),
        pending,
      );
    },
  );

  test(
    'pull apply rollback retains cursor and suppresses upload echoes',
    () async {
      await sync.bindGuestDatabase(a);
      await expectLater(
        sync.applyPage(a, 0, 1, (tx) async {
          await tx.update('sync_state', {'last_error': 'should rollback'});
          throw StateError('malformed payload');
        }),
        throwsStateError,
      );
      expect((await db.query('sync_state')).single['pull_cursor'], 0);
      expect((await db.query('sync_scope')).single['applying_remote'], 0);
      expect((await db.query('sync_state')).single['last_error'], isNull);
      await sync.applyPage(a, 0, 1, (tx) async {
        await tx.insert('settings', {
          'id': 'remote',
          'settingKey': 'language',
          'value': 'en',
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          'syncStatus': 'synced',
        });
      });
      expect(
        await db.query('sync_queue', where: "entity_type = 'setting'"),
        isEmpty,
      );
      expect((await db.query('sync_state')).single['pull_cursor'], 1);
      await expectLater(
        sync.applyPage(a, 0, 2, (tx) async {}),
        throwsStateError,
      );
    },
  );

  test(
    'conflicts preserve payload and never claim successful full sync',
    () async {
      await sync.bindGuestDatabase(a);
      await repo.saveProject('Keep me', null);
      final job = (await sync.next(a, snapshot))!;
      await sync.conflict(job, 'revision_changed', {'name': 'Other device'});
      expect(
        (await db.query('sync_conflicts')).single['reason'],
        'revision_changed',
      );
      await sync.completeCycle(a);
      expect((await db.query('sync_state')).single['last_sync_at'], isNull);
      expect((await repo.projects()).single.name, 'Keep me');
    },
  );

  test(
    'UUID union converges, ignores count_after and surfaces negative conflicts',
    () {
      Map<String, Object?> event(String id, int delta, int after) => {
        'id': id,
        'user_id': a,
        'project_id': 'p',
        'delta': delta,
        'count_after': after,
      };
      final first = event('1', 10, 10),
          second = event('2', 2, 12),
          third = event('3', 3, 13);
      final merged = LedgerMerge.combine(
        a,
        'p',
        [first, second],
        [first, third],
      );
      expect(merged.balance, BigInt.from(15));
      expect(
        LedgerMerge.combine(a, 'p', [first, third], [first, second]).balance,
        merged.balance,
      );
      expect(merged.events, hasLength(3));
      expect(
        LedgerMerge.combine(
          a,
          'p',
          [
            {...first, 'created_at': '2026-09-15T00:00:00Z'},
          ],
          [
            {...first, 'created_at': '2026-09-15T08:00:00+08:00'},
          ],
        ).balance,
        BigInt.from(10),
      );
      expect(
        () => LedgerMerge.combine(a, 'p', [first], [event('1', 11, 11)]),
        throwsStateError,
      );
      expect(() => LedgerMerge.combine(b, 'p', [], [first]), throwsStateError);
      final negative = LedgerMerge.combine(
        a,
        'p',
        [event('a', 1, 1), event('b', -1, 0)],
        [event('c', -1, 0)],
      );
      expect(negative.balance, BigInt.from(-1));
      expect(negative.requiresResolution, isTrue);
      expect(negative.events, hasLength(3));
    },
  );
}
