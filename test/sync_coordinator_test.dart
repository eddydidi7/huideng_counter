import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/sync/local_sync_store.dart';
import 'package:huideng_counter/data/sync/sync_coordinator.dart';

class FakeGateway implements SyncGateway {
  bool offline = true;
  final requests = <SyncJob>[];
  Completer<PushReply>? held;
  @override
  Future<PushReply> push(SyncJob job) async {
    requests.add(job);
    if (held != null) return held!.future;
    if (offline) throw const SyncFailure('offline');
    return PushReply.accepted(requests.length);
  }

  @override
  Future<PullPage> pull(int after) async => PullPage(after, [], hasMore: false);
}

void main() {
  const user = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'offline writes continue and next successful wake drains persisted queue',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      var now = DateTime.utc(2026, 9, 15);
      final store = LocalSyncStore(db, clock: () => now);
      await store.bindGuestDatabase(user);
      await repo.saveProject('Offline', null);
      final id = (await repo.projects()).single.id;
      final session = await repo.beginSession(id);
      await repo.increment(session);
      final gateway = FakeGateway();
      var cycle = Completer<void>();
      final coordinator = SyncCoordinator(
        local: store,
        remote: gateway,
        userId: user,
        authenticatedUserId: () => user,
        snapshot: (tx, kind, id) async => {'kind': kind, 'id': id},
        consume: (tx, changes) async {},
        onStatus: (s) {
          if (s == 'cycle_finished' && !cycle.isCompleted) cycle.complete();
        },
      );
      coordinator.start();
      await cycle.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect((await db.query('sync_state')).single['last_sync_at'], isNull);
      await repo.increment(session);
      expect((await repo.projects()).single.total, 2);
      gateway.offline = false;
      now = now.add(const Duration(hours: 1));
      cycle = Completer<void>();
      await coordinator.wake();
      expect(await db.query('sync_queue'), isEmpty);
      expect((await db.query('sync_state')).single['last_sync_at'], isNotNull);
      expect(gateway.requests[0].requestId, gateway.requests[1].requestId);
      coordinator.stop();
      await db.close();
    },
  );
  test(
    'late response after account switch cannot acknowledge the previous outbox',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final store = LocalSyncStore(db);
      await store.bindGuestDatabase(user);
      final gateway = FakeGateway()..held = Completer<PushReply>();
      String? active = user;
      final coordinator = SyncCoordinator(
        local: store,
        remote: gateway,
        userId: user,
        authenticatedUserId: () => active,
        snapshot: (tx, kind, id) async => {'kind': kind, 'id': id},
        consume: (tx, changes) async {},
      );
      coordinator.start();
      for (var i = 0; i < 100 && gateway.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateway.requests, hasLength(1));
      active = null;
      coordinator.stop();
      gateway.held!.complete(const PushReply.accepted(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await db.query('sync_queue'), hasLength(1));
      expect(await db.query('sync_remote_versions'), isEmpty);
      await db.close();
    },
  );
}
