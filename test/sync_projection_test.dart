import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/local/account_database_manager.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/sync/local_sync_store.dart';
import 'package:huideng_counter/data/sync/snapshot_builder.dart';
import 'package:huideng_counter/data/sync/remote_projector.dart';
import 'package:huideng_counter/data/sync/sync_coordinator.dart';
import 'package:huideng_counter/domain/models.dart';

const user = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
const otherUser = 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb';

// A deterministic stand-in for the deployed RPC protocol. These tests exercise
// actual SQLite snapshots, acknowledgements and projection, without a network.
class LedgerServer {
  final feed = <Map<String, Object?>>[];
  final documents = <String, Map<String, Object?>>{};
  final events = <String, Map<String, Object?>>{};
  Future<PushReply> push(SyncJob job) async {
    final key = '${job.entityType}/${job.entityId}';
    final old = job.entityType == 'event'
        ? events[job.entityId]
        : documents[key];
    if (job.entityType == 'event' && old != null) {
      return PushReply.accepted(old['revision'] as int);
    }
    if (job.entityType != 'event' &&
        job.payload['base_revision'] != (old?['revision'] ?? 0)) {
      return PushReply.conflict('revision_changed', old);
    }
    final revision = feed.length + 1;
    final data = job.entityType == 'event'
        ? <String, Object?>{...job.payload, 'revision': revision}
        : <String, Object?>{
            'user_id': job.userId,
            'id': job.entityId,
            'revision': revision,
            'data': job.payload['data'],
          };
    feed.add({
      'user_id': job.userId,
      'kind': job.entityType,
      'entity_id': job.entityId,
      'revision': revision,
      'payload': data,
    });
    if (job.entityType == 'event') {
      events[job.entityId] = data;
    } else {
      documents[key] = data;
    }
    return PushReply.accepted(revision);
  }

  Future<void> pull(Database db) async {
    final store = LocalSyncStore(db);
    final cursor = (await db.query('sync_state')).single['pull_cursor'] as int;
    final rows = feed.where((r) => (r['revision'] as int) > cursor).toList();
    await store.applyPage(
      user,
      cursor,
      feed.length,
      (tx) => RemoteProjector(user).apply(tx, rows),
    );
  }

  Future<void> sync(Database db) async {
    final store = LocalSyncStore(db);
    for (var i = 0; i < 100; i++) {
      final job = await store.next(user, SyncSnapshots(store).build);
      if (job == null) break;
      final reply = await push(job);
      if (reply.conflict != null) {
        await store.conflict(job, reply.conflict!, reply.remote);
      } else {
        await store.acknowledge(job, reply.revision!);
      }
    }
    await pull(db);
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late Database a, b;
  late SqliteCounterRepository ra, rb;
  late LedgerServer server;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('huideng_projection_');
    a = await LocalDatabase.openAt('${dir.path}/a.sqlite');
    b = await LocalDatabase.openAt('${dir.path}/b.sqlite');
    for (final db in [a, b]) {
      await LocalSyncStore(db).bindGuestDatabase(user);
      await db.delete('sync_queue');
    }
    ra = SqliteCounterRepository(a);
    rb = SqliteCounterRepository(b);
    server = LedgerServer();
  });
  tearDown(() async {
    await a.close();
    await b.close();
    if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
        !dir.path.contains('huideng_projection_')) {
      throw StateError('Unsafe temp path');
    }
    await dir.delete(recursive: true);
  });

  test(
    'two offline devices union UUID events, restore histories and never double count echoes',
    () async {
      await ra.saveProject('阿弥陀佛', null);
      final id = (await ra.projects()).single.id;
      await server.sync(a);
      await server.sync(b);
      final sa = await ra.beginSession(id), sb = await rb.beginSession(id);
      await ra.increment(sa, source: CountSource.volumeUp);
      await rb.increment(sb, source: CountSource.screen);
      await ra.endSession(sa);
      await rb.endSession(sb);
      await server.sync(a);
      await server.sync(b);
      await server.sync(a);
      expect((await ra.projects()).single.total, 2);
      expect((await rb.projects()).single.total, 2);
      expect((await ra.projects()).single.today, 2);
      expect(await ra.changes(id), hasLength(2));
      expect(await rb.history(id), hasLength(2));
      expect((await rb.changes(id)).map((r) => r['source']).toSet(), {
        'screen',
        'volumeUp',
      });
      await server.sync(a);
      await server.sync(b);
      expect(server.events, hasLength(2));
      expect(await a.query('sync_queue'), isEmpty);
      expect(await b.query('sync_queue'), isEmpty);
      await ra.correct(id, CorrectionMode.set, 10, '校正');
      await server.sync(a);
      await server.sync(b);
      expect((await rb.projects()).single.total, 10);
      expect((await rb.changes(id)).first['delta'], 8);
      expect((await rb.changes(id)).first['note'], '校正');
    },
  );

  test(
    'concurrent metadata retains local edit and server revision for explicit conflict handling',
    () async {
      await ra.saveProject('Original', null);
      final id = (await ra.projects()).single.id;
      await server.sync(a);
      await server.sync(b);
      final old = (await b.query(
        'sync_remote_versions',
        where: "entity_type='project'",
      )).single['server_revision'];
      await ra.saveProject('Cloud edit', null, id: id);
      await rb.saveProject('Offline edit', null, id: id);
      await server.sync(a);
      // Pull before local snapshot: must not silently advance the edit's base.
      await server.pull(b);
      expect((await rb.projects()).single.name, 'Offline edit');
      expect(
        (await b.query(
          'sync_remote_versions',
          where: "entity_type='project'",
        )).single['server_revision'],
        old,
      );
      await server.sync(b);
      expect((await b.query('sync_queue')).single['state'], 'conflict');
      expect(
        (await b.query('sync_conflicts')).single['reason'],
        'revision_changed',
      );
      expect((await rb.projects()).single.name, 'Offline edit');
    },
  );

  test(
    'concurrent subtraction preserves negative ledger and adds an audited resolution',
    () async {
      await ra.saveProject('Negative', null);
      final id = (await ra.projects()).single.id;
      await ra.correct(id, CorrectionMode.set, 5, 'initial');
      await server.sync(a);
      await server.sync(b);
      await ra.correct(id, CorrectionMode.subtract, 5, 'A');
      await rb.correct(id, CorrectionMode.subtract, 5, 'B');
      await server.sync(a);
      await server.sync(b);
      await server.sync(a);
      expect((await ra.projects()).single.displayTotal, '-5');
      expect((await ra.projects()).single.needsReview, isTrue);
      expect(await ra.changes(id), hasLength(3));
      final session = await ra.beginSession(id);
      await expectLater(ra.increment(session), throwsRangeError);
      await ra.endSession(session);
      await ra.correct(id, CorrectionMode.set, 0, 'Resolve overlap');
      await server.sync(a);
      await server.sync(b);
      expect((await rb.projects()).single.total, 0);
      expect(server.events, hasLength(4));
    },
  );

  test('remote open session is not closed by local crash recovery', () async {
    await ra.saveProject('Active', null);
    final id = (await ra.projects()).single.id;
    final session = await ra.beginSession(id);
    await ra.increment(session);
    await server.sync(a);
    await server.sync(b);
    await rb.recoverSessions();
    expect((await b.query('sessions')).single['endAt'], isNull);
    expect(await b.query('sync_queue'), isEmpty);
    await ra.recoverSessions();
    expect((await a.query('sessions')).single['endAt'], isNotNull);
  });

  test('foreign user page rolls back and does not advance cursor', () async {
    final store = LocalSyncStore(b);
    await expectLater(
      store.applyPage(
        user,
        0,
        1,
        (tx) => RemoteProjector(user).apply(tx, [
          {'user_id': otherUser},
        ]),
      ),
      throwsStateError,
    );
    expect((await b.query('sync_state')).single['pull_cursor'], 0);
    expect((await b.query('sync_scope')).single['applying_remote'], 0);
  });

  test(
    'image download ack cannot overwrite a newer local image choice',
    () async {
      await ra.saveProject('Image', null);
      final id = (await ra.projects()).single.id;
      await server.sync(a);
      await server.sync(b);
      final data = {
        'name': 'Image',
        'image_key': '$user/$id/hash.png',
        'deleted_at': null,
      };
      final revision = server.feed.length + 1;
      await LocalSyncStore(b).applyPage(
        user,
        server.feed.length,
        revision,
        (tx) => RemoteProjector(user).apply(tx, [
          {
            'user_id': user,
            'entity_id': id,
            'revision': revision,
            'kind': 'project',
            'payload': {
              'user_id': user,
              'id': id,
              'revision': revision,
              'data': data,
            },
          },
        ]),
      );
      final store = LocalSyncStore(b);
      final job = (await store.next(user, SyncSnapshots(store).build))!;
      expect(job.entityType, 'download');
      await rb.saveProject('Image', 'new-local.png', id: id);
      await store.acknowledge(
        job,
        0,
        result: {'image_key': data['image_key'], 'path': 'old-downloaded.png'},
      );
      expect((await rb.projects()).single.imagePath, 'new-local.png');
    },
  );

  test(
    'guest import is idempotent and prevents assignment to another account',
    () async {
      final guest = await LocalDatabase.openAt('${dir.path}/guest.sqlite');
      final repo = SqliteCounterRepository(guest);
      await repo.saveProject('Guest', null);
      final id = (await repo.projects()).single.id;
      final session = await repo.beginSession(id);
      await repo.increment(session);
      await repo.endSession(session);
      final before = await guest.query('count_changes');
      final manager = AccountDatabaseManager(dir, guest);
      await manager.importGuest(user);
      await manager.importGuest(user);
      final imported = await manager.open(user);
      expect(await imported.query('count_changes'), hasLength(1));
      expect(
        (await SqliteCounterRepository(imported).projects()).single.total,
        1,
      );
      await manager.importGuest(otherUser);
      final other = await manager.open(otherUser);
      expect(await other.query('projects'), isEmpty);
      expect(await guest.query('count_changes'), before);
      await imported.close();
      await other.close();
      await guest.close();
    },
  );
}
