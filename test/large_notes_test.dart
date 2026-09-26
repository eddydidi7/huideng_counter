import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/domain/large_note.dart';
import 'package:huideng_counter/domain/note_reader.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'five million Chinese characters round trip, bounded chunks and local search',
    () async {
      final text = '闻思修行法' * 1000000;
      expect(text.runes.length, 5000000);
      final chunks = splitNoteForEditing(text);
      expect(chunks.length, greaterThan(300));
      final joined = joinNoteChunks(chunks);
      expect((jsonDecode(joined) as List).map((e) => e['insert']).join(), text);
      final paragraphs = readerParagraphs(text);
      expect(paragraphs.every((p) => p.text.length <= 2048), true);
      expect(paragraphs.map((p) => p.text).join(), text);
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = NotesRepository(db);
      final first = await repo.save({'title': '长文', 'body': text});
      expect((await repo.get(first['id'] as String))['body'], text);
      final rows = await repo.list(search: '闻思修行法');
      expect(rows.length, 1);
      expect((rows.single['body'] as String).length, lessThanOrEqualTo(2000));
      await repo.save({...rows.single, 'isFavorite': 1});
      expect((await repo.get(first['id'] as String))['body'], text);
      await expectLater(
        repo.save({...first, 'body': '字' * 5000001}),
        throwsStateError,
      );
      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('rich chunk boundaries preserve styled text and surrogate pairs', () {
    final body = jsonEncode([
      {
        'insert': '甲' * 15999 + '😀尾',
        'attributes': {'bold': true},
      },
      {
        'insert': {'image': 'https://example.test/a.png'},
      },
      {'insert': '\n'},
    ]);
    final decoded =
        jsonDecode(joinNoteChunks(splitNoteForEditing(body))) as List;
    expect(
      decoded
          .where((e) => e['insert'] is String)
          .map((e) => e['insert'])
          .join(),
      '甲' * 15999 + '😀尾\n',
    );
    expect(decoded.first['attributes']['bold'], true);
    expect(decoded.any((e) => e['insert'] is Map), true);
  });
}
