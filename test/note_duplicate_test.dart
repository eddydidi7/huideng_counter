import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/presentation/note_tools.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('noteDisplayTitle prefers the title field, falls back to the first body line', () async {
    expect(noteDisplayTitle({'title': '标题', 'body': '[]'}), '标题');
    expect(
      noteDisplayTitle({
        'title': '',
        'body': '[{"insert":"无量寿经9月30日\\n第二行"}]',
      }),
      '无量寿经9月30日',
    );
    expect(noteDisplayTitle({'title': '', 'body': ''}), '空白笔记');
  });

  test('nextCopyTitle avoids collisions and numbers subsequent copies', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    try {
      final repo = NotesRepository(db);
      await repo.save({'title': '无量寿经9月30日', 'body': '[]'});
      expect(await nextCopyTitle(repo, '无量寿经9月30日'), '无量寿经9月30日 - 副本');
      await repo.save({'title': '无量寿经9月30日 - 副本', 'body': '[]'});
      expect(await nextCopyTitle(repo, '无量寿经9月30日'), '无量寿经9月30日 - 副本 2');
      await repo.save({'title': '无量寿经9月30日 - 副本 2', 'body': '[]'});
      expect(await nextCopyTitle(repo, '无量寿经9月30日'), '无量寿经9月30日 - 副本 3');
    } finally {
      await db.close();
    }
  });

  test('duplicating an already-duplicated note renames from its base title, not "- 副本 - 副本"', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    try {
      final repo = NotesRepository(db);
      await repo.save({'title': '无量寿经9月30日', 'body': '[]'});
      await repo.save({'title': '无量寿经9月30日 - 副本', 'body': '[]'});
      expect(
        await nextCopyTitle(repo, '无量寿经9月30日 - 副本'),
        '无量寿经9月30日 - 副本 2',
      );
    } finally {
      await db.close();
    }
  });

  test('a duplicated note is a fully independent row: different id, editing one leaves the other unchanged', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    try {
      final repo = NotesRepository(db);
      final original = await repo.save({
        'title': '原笔记',
        'body': '[{"insert":"正文\\n"}]',
        'source_meta': '{"notebook":"甲"}',
      });
      final copyTitle = await nextCopyTitle(repo, '原笔记');
      final copy = await repo.save({
        'title': copyTitle,
        'body': original['body'],
        'source_post_id': original['source_post_id'],
        'source_meta': original['source_meta'],
      });
      expect(copy['id'], isNot(original['id']));
      expect(copy['title'], '原笔记 - 副本');
      expect(copy['body'], original['body']);
      expect(NotesRepository.categoriesOf(copy), ['甲']);

      // Editing the copy must not touch the original.
      await repo.save({...copy, 'body': '[{"insert":"改过的正文\\n"}]'});
      final reloadedOriginal = await repo.get(original['id'] as String);
      expect(reloadedOriginal['body'], original['body']);

      // Deleting the original must not affect the copy.
      await repo.save({
        ...reloadedOriginal,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      });
      final reloadedCopy = await repo.get(copy['id'] as String);
      expect(reloadedCopy['deletedAt'], isNull);
    } finally {
      await db.close();
    }
  });
}
