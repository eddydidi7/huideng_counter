import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/core/app_links_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/repositories/app_links_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets('public feed is independent and themes persist', (tester) async {
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final app = AppController(SqliteCounterRepository(db));
    await app.set('language', 'zh');
    app.appLinks =
        AppLinksController(
            AppLinksRepository(HomeMessageCache(cacheKey: 'test-public')),
          )
          ..value = {
            'offering_url': 'https://example.com/offering',
            'published_notes': [
              {
                'id': 'public-1',
                'body': '后台公开正文',
                'updated_at': '2026-09-16T00:00:00Z',
              },
            ],
          };
    await tester.pumpWidget(HuidengApp(controller: app));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    await app.set('colorPreference', 'dark');
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await app.reload();
    expect(app.colorPreference, 'dark');
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('笔记菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资料'));
    await tester.pumpAndSettle();
    expect(find.text('后台公开正文'), findsOneWidget);
    expect(await db.query('notes'), isEmpty);
    await tester.tap(find.text('后台公开正文'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    app.appLinks?.dispose();
    app.dispose();
    await db.close();
  });
}
