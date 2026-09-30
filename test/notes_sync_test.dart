import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/data/sync/local_sync_store.dart';
import 'package:huideng_counter/data/sync/notes_sync.dart';

const owner = '00000000-0000-4000-8000-000000000001';

class Server implements NotesGateway {
  final rows = <String, Map<String, dynamic>>{};
  final receipts = <String, Map<String, dynamic>>{};
  int revision = 0;
  bool offline = false, loseReply = false;
  Future<void> Function()? duringPush;
  @override
  Future<Map<String, dynamic>> push(Map<String, dynamic> req) async {
    if (offline) throw StateError('offline');
    final rid = req['p_request'] as String;
    if (receipts.containsKey(rid)) return receipts[rid]!;
    final old = rows[req['p_id']];
    final conflict = old != null && old['revision'] != req['p_base'];
    final id = conflict ? rid : req['p_id'] as String;
    final saved = <String, dynamic>{
      'user_id': owner,
      'id': id,
      'data': req['p_data'],
      'history': req['p_history'],
      'revision': ++revision,
      'conflict_of': conflict ? req['p_id'] : null,
    };
    rows[id] = saved;
    final reply = {
      'saved': saved,
      'conflict': conflict,
      'current': conflict ? old : null,
    };
    receipts[rid] = reply;
    final hook = duringPush;
    duringPush = null;
    await hook?.call();
    if (loseReply) {
      loseReply = false;
      throw StateError('lost response');
    }
    return reply;
  }

  @override
  Future<List<Map<String, dynamic>>> pull(int cursor) async {
    if (offline) throw StateError('offline');
    final result = rows.values
        .where((r) => (r['revision'] as int) > cursor)
        .toList();
    result.sort(
      (a, b) => (a['revision'] as int).compareTo(b['revision'] as int),
    );
    return result.take(100).toList();
  }
}

Future<Database> database() async {
  final dir = await Directory.systemTemp.createTemp('huideng_sync_test_');
  addTearDown(() async {
    if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
        !dir.path.contains('huideng_sync_test_')) {
      throw StateError('Unsafe path');
    }
    await dir.delete(recursive: true);
  });
  final db = await LocalDatabase.openAt('${dir.path}/db.sqlite');
  await LocalSyncStore(db).bindGuestDatabase(owner);
  return db;
}

Future<void> cycle(NotesSync s) async {
  s.start();
  await s.waitUntilIdle();
  await s.wake(force: true);
  s.stop();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'pin survives reopen and sync; unpin restores title sorting without truncation',
    () async {
      var a = await database();
      final b = await database();
      final body = 'Z pinned ${'long body ' * 400}';
      var note = await NotesRepository(a).save({'body': body, 'isPinned': 1});
      await NotesRepository(a).setQuickAccess(note['id'] as String, true);
      await NotesRepository(
        a,
      ).addCategories([note['id'] as String], ['经论', '常读']);
      await NotesRepository(a).save({'body': 'A ordinary'});
      final path = a.path;
      await a.close();
      a = await LocalDatabase.openAt(path);
      final server = Server();
      final sa = NotesSync(a, server, owner, () => owner);
      final sb = NotesSync(b, server, owner, () => owner);
      try {
        expect(
          (await NotesRepository(
            a,
          ).list(sort: 'title', ascending: true)).first['id'],
          note['id'],
        );
        expect(
          (await NotesRepository(
            a,
          ).list(search: 'Z pinned')).single['isPinned'],
          1,
        );
        await cycle(sa);
        await cycle(sb);
        note = await NotesRepository(b).get(note['id'] as String);
        expect(note['isPinned'], 1);
        expect(NotesRepository.isQuickAccess(note), isTrue);
        expect(NotesRepository.categoriesOf(note), ['经论', '常读']);
        expect(note['body'], body);
        await NotesRepository(b).save({...note, 'isPinned': 0});
        await cycle(sb);
        await cycle(sa);
        expect(
          (await NotesRepository(a).get(note['id'] as String))['isPinned'],
          0,
        );
        expect(
          (await NotesRepository(
            a,
          ).list(sort: 'title', ascending: true)).first['body'],
          'A ordinary',
        );
        expect(
          (await NotesRepository(a).get(note['id'] as String))['body'],
          body,
        );
      } finally {
        sa.stop();
        sb.stop();
        await a.close();
        await b.close();
      }
    },
  );
  test(
    'v7 upgrade keeps original favorites and adds Favorites 2 empty',
    () async {
      var db = await database();
      final path = db.path;
      final n = await NotesRepository(
        db,
      ).save({'body': '已有收藏', 'isFavorite': 1});
      await db.execute('DROP TRIGGER note_queue_update');
      await db.execute('ALTER TABLE notes DROP COLUMN isFavorite2');
      await db.setVersion(7);
      await db.close();
      db = await LocalDatabase.openAt(path);
      try {
        final row = await NotesRepository(db).get(n['id'] as String);
        expect(row['isFavorite'], 1);
        expect(row['isFavorite2'], 0);
        expect(row['body'], '已有收藏');
      } finally {
        await db.close();
      }
    },
  );
  test(
    'legacy Favorites 2 merges into one offline and synced favorite state',
    () async {
      final a = await database(), b = await database();
      final server = Server()..offline = true;
      final repo = NotesRepository(a);
      var note = await repo.save({
        'body': '离线收藏',
        'isFavorite': 1,
        'isFavorite2': 1,
      });
      final sa = NotesSync(a, server, owner, () => owner),
          sb = NotesSync(b, server, owner, () => owner);
      try {
        await cycle(sa);
        expect((await repo.list(folder: 'favorites')).length, 1);
        note = await repo.save({...note, 'isFavorite': 0});
        expect(await repo.list(folder: 'favorites'), isEmpty);
        expect(await repo.list(folder: 'favorites2'), isEmpty);
        server.offline = false;
        await cycle(sa);
        await cycle(sa);
        await cycle(sb);
        expect(
          (await NotesRepository(b).get(note['id'] as String))['isFavorite2'],
          0,
        );
        note = await repo.save({
          ...await repo.get(note['id'] as String),
          'isFavorite2': 0,
        });
        await cycle(sa);
        await cycle(sb);
        expect(await NotesRepository(b).list(folder: 'favorites2'), isEmpty);
      } finally {
        sa.stop();
        sb.stop();
        await a.close();
        await b.close();
      }
    },
  );
  test(
    'large frozen request preserves list access and exact retry payload',
    () async {
      final db = await database();
      final sync = NotesSync(db, Server(), owner, () => owner);
      try {
        final note = await NotesRepository(db).save({'body': '保留的笔记'});
        final request = await sync.freeze();
        final large = {
          ...request!,
          'test_history': List.filled(400000, '中文🙏').join(),
        };
        await db.update(
          'note_outbox',
          {'payload': jsonEncode(large)},
          where: 'note_id=?',
          whereArgs: [note['id']],
        );
        expect((await NotesRepository(db).list()).single['body'], '保留的笔记');
        final retried = await sync.freeze();
        expect(retried, large);
        expect(retried!['p_request'], request['p_request']);
      } finally {
        sync.stop();
        await db.close();
      }
    },
  );
  test(
    'missing authentication is visible; manual retry resumes without duplicates',
    () async {
      final db = await database();
      final server = Server();
      String? user;
      final sync = NotesSync(db, server, owner, () => user);
      try {
        await NotesRepository(db).save({'body': 'body-only note'});
        await sync.wake(force: true);
        expect(sync.status, 'waiting_login');
        expect(server.rows, isEmpty);
        expect(await db.query('note_outbox'), hasLength(1));
        user = owner;
        await sync.wake(force: true);
        await sync.waitUntilIdle();
        await sync.wake(force: true);
        expect(sync.status, 'synced');
        expect(server.rows, hasLength(1));
        expect(server.rows.values.single['data']['title'], '');
        expect(await db.query('note_outbox'), isEmpty);
      } finally {
        sync.stop();
        await sync.waitUntilIdle();
        await db.close();
      }
    },
  );
  test(
    'offline save, restart retry, second-device recovery, trash and restore',
    () async {
      final a = await database(), b = await database();
      final server = Server()..offline = true;
      final sa = NotesSync(a, server, owner, () => owner),
          sb = NotesSync(b, server, owner, () => owner);
      try {
        var note = await NotesRepository(
          a,
        ).save({'title': '闻思', 'body': '离线内容'});
        await cycle(sa);
        expect(sa.status, 'failed');
        expect(await a.query('note_outbox'), hasLength(1));
        server.offline = false;
        await cycle(sa);
        await cycle(sb);
        expect((await b.query('notes')).single['body'], '离线内容');
        expect(await b.query('note_outbox'), isEmpty);
        note = await NotesRepository(a).save({
          ...note,
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await cycle(sa);
        await cycle(sb);
        expect(await NotesRepository(b).list(), isEmpty);
        await NotesRepository(a).save({...note, 'deletedAt': null});
        await cycle(sa);
        await cycle(sb);
        expect(await NotesRepository(b).list(), hasLength(1));
      } finally {
        sa.stop();
        sb.stop();
        await a.close();
        await b.close();
      }
    },
  );
  test(
    'concurrent edits retain both copies, newer in-flight edits and idempotent retries',
    () async {
      final a = await database(), b = await database();
      final server = Server();
      final sa = NotesSync(a, server, owner, () => owner),
          sb = NotesSync(b, server, owner, () => owner);
      try {
        await NotesRepository(a).save({'title': '课程', 'body': '最初'});
        await cycle(sa);
        await cycle(sb);
        final oldA = (await a.query('notes')).single,
            oldB = (await b.query('notes')).single;
        await NotesRepository(a).save({...oldA, 'body': '设备 A'});
        await cycle(sa);
        final editB = await NotesRepository(b).save({...oldB, 'body': '设备 B'});
        server.loseReply = true;
        server.duringPush = () async {
          await NotesRepository(b).save({...editB, 'body': '设备 B 最新编辑'});
        };
        sb.start();
        await sb.waitUntilIdle();
        sb.stop();
        final frozen = jsonDecode(
          (await b.query('note_outbox')).single['payload'] as String,
        );
        expect(frozen['p_data']['body'], '设备 B');
        await cycle(sb);
        await cycle(sa);
        expect(server.rows, hasLength(2));
        expect((await a.query('notes')).map((r) => r['body']).toSet(), {
          '设备 A',
          '设备 B 最新编辑',
        });
        expect((await b.query('notes')).map((r) => r['body']).toSet(), {
          '设备 A',
          '设备 B 最新编辑',
        });
        expect(await b.query('note_outbox'), isEmpty);
        await expectLater(
          NotesRepository(b).save({...editB, 'body': 'stale editor'}),
          throwsA(isA<NoteConflict>()),
        );
      } finally {
        sa.stop();
        sb.stop();
        await a.close();
        await b.close();
      }
    },
  );
  test(
    'account switch during HTTP does not apply response or clear pending note',
    () async {
      final db = await database(), server = Server();
      String? user = owner;
      final sync = NotesSync(db, server, owner, () => user);
      try {
        await NotesRepository(db).save({'body': 'private'});
        server.duringPush = () async {
          user = 'other';
        };
        await cycle(sync);
        expect(await db.query('note_outbox'), hasLength(1));
        expect(await db.query('note_cloud'), isEmpty);
      } finally {
        sync.stop();
        await db.close();
      }
    },
  );
}
