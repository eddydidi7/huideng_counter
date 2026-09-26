import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/presentation/masonry_posts.dart';
import 'package:huideng_counter/services/solar_reminder_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test('archived favorites remain in all notes and search; trash stays separate', () async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final repo = NotesRepository(db);
    final n = await repo.save({'title': '归档课程', 'body': '心经资料', 'isArchived': 1, 'isFavorite': 1, 'isFavorite2': 1});
    for (final folder in ['active', 'archive', 'favorites', 'favorites2']) {
      expect((await repo.list(folder: folder, search: '心经')).single['id'], n['id']);
    }
    await repo.save({...n, 'deletedAt': DateTime.now().toIso8601String()});
    expect(await repo.list(), isEmpty);
    expect(await repo.list(folder: 'trash'), hasLength(1));
    await db.close();
  });
  test('three minute reminder inherits old choice without resetting new choice', () async {
    SharedPreferences.setMockInitialValues({'solar_remind_10': true});
    expect(await SolarReminderService.instance.enabled(3), isTrue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('solar_remind_3', false);
    expect(await SolarReminderService.instance.enabled(3), isFalse);
    expect(prefs.getBool('solar_remind_10'), isTrue);
  });
  for (final width in [320.0, 360.0, 412.0, 480.0]) {
    testWidgets('masonry fills shorter column at width $width', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: width,
        child: MasonryPosts(children: const [SizedBox(key: ValueKey('a'), height: 180), SizedBox(key: ValueKey('b'), height: 60), SizedBox(key: ValueKey('c'), height: 80)])))));
      final a = tester.getRect(find.byKey(const ValueKey('a')));
      final b = tester.getRect(find.byKey(const ValueKey('b')));
      final c = tester.getRect(find.byKey(const ValueKey('c')));
      expect(c.left, b.left);
      expect(c.top, b.bottom);
      expect(c.top, lessThan(a.bottom));
      expect(c.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    });
  }
}
