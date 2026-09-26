import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/core/cloud_controller.dart';
import 'package:huideng_counter/data/local/account_database_manager.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/note_categories.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/account_panel.dart';
import 'package:huideng_counter/presentation/my_page.dart';

const user = '11111111-1111-4111-8111-111111111111';
const otherUser = '22222222-2222-4222-8222-222222222222';

NoteCategories categoriesOf(Database db) {
  final settings = SqliteCounterRepository(db);
  String? value;
  return NoteCategories(
    NotesRepository(db),
    () => value,
    (next) async {
      value = next;
      await settings.saveSetting(NoteCategories.settingKey, next);
    },
  );
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('create, rename, reorder and delete categories without losing notes', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final notes = NotesRepository(db);
    final store = categoriesOf(db);
    final a = await notes.save({'title': '', 'body': '甲'});
    final b = await notes.save({'title': '', 'body': '乙'});
    await notes.save({'title': '', 'body': '丙'});

    await store.create('佛法');
    await store.create('澳洲');
    expect(() => store.create('佛法'), throwsStateError);
    expect(() => store.create('未分类'), throwsStateError);
    await notes.setCategory([a['id'] as String, b['id'] as String], '佛法');

    var data = await store.load();
    expect(data.names, ['佛法', '澳洲']);
    expect(data.counts, {'佛法': 2, '': 1});

    await store.rename('佛法', '经论');
    data = await store.load();
    expect(data.names, ['经论', '澳洲']);
    expect(data.counts['经论'], 2);

    await store.reorder(['澳洲', '经论']);
    expect((await store.load()).names, ['澳洲', '经论']);

    await store.delete('经论');
    data = await store.load();
    expect(data.names, ['澳洲']);
    expect(data.counts, {'': 3});
    expect(await notes.list(), hasLength(3));
    await db.close();
  });

  test('moving category keeps favorite, archive and time order', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final notes = NotesRepository(db);
    final old = await notes.save({
      'title': '',
      'body': '旧笔记',
      'isFavorite': 1,
      'isArchived': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await notes.save({'title': '', 'body': '新笔记'});
    final before = (await notes.list()).map((n) => n['id']).toList();

    await notes.setCategory([old['id'] as String], '佛法');
    final moved = await notes.get(old['id'] as String);
    expect(NotesRepository.categoryOf(moved), '佛法');
    expect(moved['isFavorite'], 1);
    expect(moved['isArchived'], 1);
    expect(moved['updatedAt'], old['updatedAt']);
    expect((await notes.list()).map((n) => n['id']).toList(), before);

    // Favoriting later must not change the category either.
    await notes.save({...moved, 'isFavorite': 0});
    expect(
      NotesRepository.categoryOf(await notes.get(old['id'] as String)),
      '佛法',
    );
    // The change is queued for cloud sync with the note itself.
    expect(
      await db.query(
        'note_outbox',
        where: 'note_id=?',
        whereArgs: [old['id']],
      ),
      hasLength(1),
    );
    await db.close();
  });

  test('guest notes and categories follow the registered account once', () async {
    final dir = await Directory.systemTemp.createTemp('huideng_category_test_');
    final guest = await LocalDatabase.openAt('${dir.path}/guest.sqlite');
    try {
      final notes = NotesRepository(guest);
      await categoriesOf(guest).create('空分类');
      final note = await notes.save({'title': '', 'body': '访客笔记'});
      await notes.setCategory([note['id'] as String], '佛法');

      final manager = AccountDatabaseManager(dir, guest);
      await manager.importGuest(user);
      await manager.importGuest(user);
      final account = await manager.open(user);
      final imported = await NotesRepository(account).list();
      expect(imported, hasLength(1));
      expect(NotesRepository.categoryOf(imported.single), '佛法');
      expect(await account.query('note_outbox'), hasLength(1));
      expect(
        NoteCategories.decode(
          (await SqliteCounterRepository(
            account,
          ).settings())[NoteCategories.settingKey],
        ),
        ['空分类'],
      );

      await manager.importGuest(otherUser);
      final other = await manager.open(otherUser);
      expect(await other.query('notes'), isEmpty);
      expect(await guest.query('notes'), hasLength(1));
      await account.close();
      await other.close();
    } finally {
      await guest.close();
      if (!dir.path.contains('huideng_category_test_')) {
        throw StateError('Unsafe path');
      }
      await dir.delete(recursive: true);
    }
  });

  testWidgets('Common opens the same account and sync panel as Settings', (
    tester,
  ) async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final app = AppController(SqliteCounterRepository(db));
    final cloud = CloudController(
      app,
      AccountDatabaseManager(Directory.systemTemp, db),
    );
    cloud.ready = true;
    cloud.status = 'guest';
    app.cloud = cloud;
    await tester.pumpWidget(
      MaterialApp(home: SettingsServicesPage(app: app)),
    );
    await tester.tap(find.byKey(const ValueKey('common-account-sync')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSyncPage), findsOneWidget);
    final panel = tester.widget<AccountPanel>(find.byType(AccountPanel));
    expect(identical(panel.cloud, app.cloud), isTrue);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
