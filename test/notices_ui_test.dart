import 'package:shared_preferences/shared_preferences.dart';
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
  testWidgets(
    'notices tab shows localized cached content and retains account access',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.set('language', 'zh');
      final notices = NoticesController(
        NoticesRepository(HomeMessageCache(cacheKey: 'notices')),
      );
      app.notices = notices;
      notices.value = {
        'items': [
          {
            'id': 'test',
            'title_zh': '课程安排',
            'title_en': 'Course schedule',
            'body_zh': '完整正文',
            'body_en': 'Full notice text',
            'is_pinned': true,
            'published_at': '2026-09-15T00:00:00Z',
          },
        ],
      };
      await tester.pumpWidget(HuidengApp(controller: app));
      expect(find.byKey(const ValueKey('home-notices-panel')), findsOneWidget);
      expect(find.text('课程安排'), findsOneWidget);
      expect(find.text('今日念诵'), findsNothing);
      expect(find.text('一念一记 · 日积月累'), findsNothing);
      await tester.tap(find.text('课程安排'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      Navigator.of(tester.element(find.byType(SelectableText))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-services')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('my-forum-panel')), findsNothing);
      expect(find.byKey(const ValueKey('my-practice-panel')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('my-practice-panel')),
          matching: find.text('通知'),
        ),
        findsOneWidget,
      );
      expect(find.text('公共网盘'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-account')));
      await tester.pumpAndSettle();
      expect(find.text('通知与社区'), findsNothing);
      await app.set('language', 'en');
      await tester.pumpAndSettle();
      expect(find.text('Account and sync'), findsOneWidget);
      expect(find.text('Local mode'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      notices.dispose();
      app.dispose();
      await db.close();
    },
  );
}
