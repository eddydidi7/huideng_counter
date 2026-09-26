import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';

void main() {
  testWidgets(
    'long press card moves down and handle moves up; order persists',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      await repo.saveProject('First', null);
      await repo.saveProject('Second', null);
      final app = AppController(repo);
      await app.reload();
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      Future<void> settleSave() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pumpAndSettle();
      }

      final first = tester.getCenter(find.text('First'));
      final second = tester.getCenter(find.text('Second'));
      final gesture = await tester.startGesture(first);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 1));
      await tester.pump();
      await gesture.moveBy(Offset(0, (second.dy - first.dy) * 2));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await settleSave();
      await settleSave();
      expect((await repo.projects()).map((p) => p.name), ['Second', 'First']);
      final up = await tester.startGesture(tester.getCenter(find.text('First')));
      await tester.pump(const Duration(milliseconds: 600));
      await up.moveBy(const Offset(0, -1));
      await tester.pump();
      await up.moveBy(Offset(0, (first.dy - second.dy) * 2));
      await tester.pump(const Duration(milliseconds: 500));
      await up.up();
      await settleSave();
      await settleSave();
      await app.reload();
      expect(app.projects.map((p) => p.name), ['First', 'Second']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
}
