import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/backup_repository.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/sync/local_sync_store.dart';
import 'package:huideng_counter/domain/models.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  late Database a, b;
  late SqliteCounterRepository ra, rb;
  late BackupRepository ba, bb;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('huideng_backup_test_');
    a = await LocalDatabase.openAt('${dir.path}/a.sqlite');
    b = await LocalDatabase.openAt('${dir.path}/b.sqlite');
    ra = SqliteCounterRepository(a);
    rb = SqliteCounterRepository(b);
    ba = BackupRepository(a, Directory('${dir.path}/export'));
    bb = BackupRepository(b, Directory('${dir.path}/import'));
  });
  tearDown(() async {
    await a.close();
    await b.close();
    if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
        !dir.path.contains('huideng_backup_test_')) {
      throw StateError('Unsafe path');
    }
    await dir.delete(recursive: true);
  });
  Future<String> seed() async {
    final image = File('${dir.path}/test.png');
    await image.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
      ),
    );
    await ra.saveProject('阿弥陀佛', image.path);
    final id = (await ra.projects()).single.id;
    final session = await ra.beginSession(id);
    await ra.increment(session, source: CountSource.screen);
    await ra.endSession(session);
    await ra.correct(id, CorrectionMode.add, 5, '校正');
    await ra.saveSetting('language', 'en');
    return id;
  }

  test(
    'legacy second favorite restores into unified favorite without duplicates',
    () async {
      final note = await NotesRepository(
        a,
      ).save({'title': 'legacy', 'body': '保留正文'});
      await a.update(
        'notes',
        {'isFavorite': 0, 'isFavorite2': 1},
        where: 'id=?',
        whereArgs: [note['id']],
      );
      final bytes = await ba.export();
      await bb.import(bytes, restoreSettings: false);
      await bb.import(bytes, restoreSettings: false);
      final favorites = await NotesRepository(b).list(folder: 'favorites');
      expect(favorites, hasLength(1));
      expect(favorites.single['body'], '保留正文');
      expect(favorites.single['isFavorite2'], 0);
    },
  );

  test(
    'CSV exports full history, quotes text and protects formula cells',
    () async {
      final id = await seed();
      await ra.correct(id, CorrectionMode.subtract, 1, '=SUM(1,2)\n"note"');
      await ra.saveProject('Empty project', null);
      final bytes = await ba.exportCsv();
      final csv = utf8.decode(bytes);
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(csv, contains('"project_name"'));
      expect(csv, contains('"device"'));
      expect(csv, contains('阿弥陀佛'));
      expect(csv, contains('Empty project'));
      expect(csv, contains('"-1"'));
      expect(csv, contains("'=SUM(1,2)"));
      expect(csv, contains('""note""'));
      for (final row in await a.query('count_changes')) {
        expect(csv, contains(row['id'] as String));
      }
      expect((await ra.projects()).first.total, 5);
      final onlyProject = utf8.decode(await ba.exportCsv(projectId: id));
      expect(onlyProject, isNot(contains('Empty project')));
      final futureRange = utf8.decode(
        await ba.exportCsv(from: DateTime(2099), until: DateTime(2100)),
      );
      expect(futureRange.trim().split('\r\n'), hasLength(1));
    },
  );

  test(
    'roundtrip images settings history and duplicate import, keeping newer data',
    () async {
      final id = await seed();
      final bytes = await ba.export();
      expect(await bb.import(bytes, restoreSettings: true), 2);
      expect((await rb.projects()).single.total, 6);
      expect((await rb.settings())['language'], 'en');
      final restoredPath =
          (await b.query('projects')).single['imagePath'] as String;
      expect(await File(restoredPath).exists(), true);
      expect(
        await File(restoredPath).readAsBytes(),
        await File('${dir.path}/test.png').readAsBytes(),
      );
      await rb.correct(id, CorrectionMode.add, 2, 'new');
      await rb.saveProject('新名称', restoredPath, id: id);
      expect(await bb.import(bytes, restoreSettings: false), 0);
      expect((await rb.projects()).single.total, 8);
      expect((await rb.projects()).single.name, '新名称');
      expect((await b.query('count_changes')).length, 3);
      expect((await b.query('corrections')).length, 2);
    },
  );
  test(
    'same account frozen event payload and device provenance survive restore',
    () async {
      const owner = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
      await LocalSyncStore(a).bindGuestDatabase(owner);
      await LocalSyncStore(b).bindGuestDatabase(owner);
      await seed();
      final event = (await a.query('count_changes')).first['id'] as String;
      final frozen = await a.transaction(
        (tx) => LocalSyncStore(a).eventPayload(tx, event),
      );
      await bb.import(await ba.export(), restoreSettings: false);
      final restored = await b.transaction(
        (tx) => LocalSyncStore(b).eventPayload(tx, event),
      );
      expect(restored, frozen);
      expect(
        (await b.query('sync_queue', where: "entity_type='event'")).length,
        2,
      );
    },
  );
  test('cross account and corrupted file cannot modify destination', () async {
    await seed();
    final bytes = await ba.export();
    await LocalSyncStore(
      b,
    ).bindGuestDatabase('bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb');
    await expectLater(
      bb.import(bytes, restoreSettings: true),
      throwsA(isA<BackupFailure>()),
    );
    expect(await b.query('projects'), isEmpty);
    final bad = Uint8List.fromList(bytes);
    bad[bad.length ~/ 2] ^= 1;
    await expectLater(bb.import(bad, restoreSettings: true), throwsA(anything));
    expect(await b.query('projects'), isEmpty);
  });
  test('UUID conflict rolls back the complete import transaction', () async {
    await seed();
    final bytes = await ba.export();
    await bb.import(bytes, restoreSettings: false);
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final payload =
        jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    payload['tables']['count_changes'][0]['delta'] = 10;
    envelope['payload'] = jsonEncode(payload);
    envelope['sha256'] = sha256
        .convert(utf8.encode(envelope['payload'] as String))
        .toString();
    await expectLater(
      bb.import(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        restoreSettings: false,
      ),
      throwsA(isA<BackupFailure>()),
    );
    expect((await rb.projects()).single.total, 6);
    expect((await b.query('count_changes')).length, 2);
  });
}
