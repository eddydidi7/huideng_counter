import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/counter_page.dart';
import 'package:huideng_counter/services/counter_haptics.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets(
    'screen and both volume keys pulse only after saved counts; off persists',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      await repo.saveProject('震动测试', null);
      final app = AppController(repo);
      await app.reload();
      await app.set('haptics', 'true');
      final savedAtPulse = <int>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('org.huideng.counter/volume'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(CounterHaptics.channel, (_) async {
        savedAtPulse.add((await repo.projects()).single.total);
        return true;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CounterPage(app: app, project: app.projects.single),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> volume(String source) async {
        tester.binding.channelBuffers.push(
          'org.huideng.counter/volume',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('increment', source),
          ),
          (_) {},
        );
        await settle();
      }

      try {
        await tester.tap(find.byKey(const ValueKey('counter-image')));
        await settle();
        await volume('volumeUp');
        await volume('volumeDown');
        expect(savedAtPulse, [1, 2, 3]);
        await app.set('haptics', 'false');
        await settle();
        await tester.tap(find.byKey(const ValueKey('counter-image')));
        await settle();
        await volume('volumeUp');
        await volume('volumeDown');
        expect((await repo.projects()).single.total, 6);
        expect(savedAtPulse, [1, 2, 3]);
        final reloaded = AppController(repo);
        await reloaded.reload();
        expect(reloaded.haptics, false);
        reloaded.dispose();
        await app.set('haptics', 'true');
        await settle();
        await db.execute(
          "CREATE TRIGGER test_count_failure BEFORE INSERT ON count_changes BEGIN SELECT RAISE(ABORT,'test failure'); END",
        );
        await tester.tap(find.byKey(const ValueKey('counter-image')));
        await settle();
        expect((await repo.projects()).single.total, 6);
        expect(savedAtPulse, [1, 2, 3]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await db.close();
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(CounterHaptics.channel, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('org.huideng.counter/volume'),
          null,
        );
      }
    },
  );
}
