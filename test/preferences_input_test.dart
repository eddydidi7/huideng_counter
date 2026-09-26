import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'system locale follows changes and explicit language takes precedence',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale(
        'en',
        'US',
      );
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.reload();
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.text('Manjushri Counter'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      expect(find.text('Calendar'), findsOneWidget);
      tester.binding.platformDispatcher.localeTestValue = const Locale(
        'zh',
        'CN',
      );
      await tester.pumpAndSettle();
      expect(find.text('文殊计数器'), findsOneWidget);
      await app.set('language', 'en');
      await tester.pumpAndSettle();
      expect(find.text('Manjushri Counter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
      tester.binding.platformDispatcher.clearLocaleTestValue();
    },
  );

  testWidgets(
    'Android volume sources count only in foreground and adjustment is audited',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('org.huideng.counter/volume');
      final enabled = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setEnabled') enabled.add(call.arguments as bool);
        return null;
      });
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      await repo.saveSetting('language', 'zh');
      await repo.saveSetting('haptics', 'false');
      await repo.saveProject('音量测试', null);
      final app = AppController(repo);
      await app.reload();
      final id = app.projects.single.id;
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('音量测试'));
      await tester.pumpAndSettle();
      expect(enabled.last, isTrue);
      Future<void> press(String source) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('increment', source),
          ),
          (_) {},
        );
        await flush(tester);
      }

      await press('volumeUp');
      await press('volumeDown');
      expect((await repo.projects()).single.total, 2);
      expect((await repo.changes(id)).map((r) => r['source']).toSet(), {
        'volumeUp',
        'volumeDown',
      });
      // Text area and image each count once; Android space remains inactive.
      await tester.tap(find.text('本次念诵'));
      await tester.tap(find.byKey(const ValueKey('counter-image')));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await flush(tester);
      expect((await repo.projects()).single.total, 4);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await flush(tester);
      expect(enabled.last, isFalse);
      await press('volumeUp');
      expect((await repo.projects()).single.total, 4);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush(tester);
      expect(enabled.last, isTrue);
      await tester.tap(find.byTooltip('调整计数'));
      await flush(tester);
      expect(enabled.last, isFalse);
      await press('volumeUp');
      expect((await repo.projects()).single.total, 4);
      await tester.tap(find.text('-1'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存校正并记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存校正并记录'));
      await flush(tester);
      expect((await repo.projects()).single.total, 3);
      expect((await repo.changes(id)).first['source'], 'manual_subtract');
      expect(enabled.last, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
      expect(enabled.last, isFalse);
      app.dispose();
      await db.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );
}
