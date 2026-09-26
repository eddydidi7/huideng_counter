import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';
import 'package:huideng_counter/presentation/counter_page.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets(
    'tap and space count once; finish saves history; language switches',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repository = SqliteCounterRepository(db);
      await repository.saveSetting('language', 'zh');
      await repository.saveProject('Test counter', null);
      final app = AppController(repository);
      await app.reload();
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.text('文殊计数器'), findsOneWidget);
      await tester.tap(find.text('Test counter'));
      await tester.pumpAndSettle();
      expect(find.byType(CounterPage), findsOneWidget);
      expect(find.text('+1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('counter-image')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect((await repository.projects()).single.total, 2);
      await tester.ensureVisible(find.text('结束本次念诵'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束本次念诵'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.byType(CounterPage), findsNothing);
      final history = await repository.history(app.projects.single.id);
      expect(history.single['delta'], 2);
      expect(history.single['endAt'], isNotNull);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('简体中文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect((await repository.settings())['language'], 'en');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
