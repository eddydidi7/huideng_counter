import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/core/notices_controller.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/notices_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  for (final size in [const Size(360, 640), const Size(412, 892)]) {
    testWidgets('six counters fit with notices on $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      await repo.saveSetting('language', 'zh');
      for (var i = 1; i <= 7; i++) {
        await repo.saveProject('计数项目$i', null);
      }
      final app = AppController(repo);
      await app.reload();
      final notices = NoticesController(
        NoticesRepository(HomeMessageCache(cacheKey: 'six-projects')),
      );
      app.notices = notices;
      notices.value = {
        'items': [
          {
            'id': 'notice',
            'title_zh': '共修通知',
            'body_zh': '本周共修安排，请查看通知详情。',
            'published_at': '2026-09-19T00:00:00Z',
          },
        ],
      };
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      final list = find.byType(ReorderableListView);
      final bounds = tester.getRect(list);
      for (final p in app.projects.take(6)) {
        final tile = find.byKey(ValueKey(p.id));
        expect(tile, findsOneWidget);
        final rect = tester.getRect(tile);
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      notices.dispose();
      app.dispose();
      await db.close();
    });
  }
}
