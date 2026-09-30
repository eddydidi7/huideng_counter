import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/app_update_page.dart';
import 'package:huideng_counter/services/app_release.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  for (final force in [false, true]) {
    testWidgets(
      'initial forced=$force update keeps correct back policy even if refresh fails',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = await LocalDatabase.openAt(inMemoryDatabasePath);
        final app = AppController(SqliteCounterRepository(db));
        final release = AppRelease({
          'version_code': 75,
          'version_name': '1.0.74',
          'apk_size': 200000000,
          'download_url': 'https://example.test/app.apk',
          'sha256': 'a' * 64,
          'release_notes': '新版本改进',
          'published_at': '2026-01-01T00:00:00Z',
          'minimum_version_code': force ? 70 : 0,
        });
        await tester.pumpWidget(
          MaterialApp(
            home: AppUpdatePage(
              app: app,
              initialRelease: release,
              installedCode: 69,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, !force);
        expect(find.text('稍后更新'), force ? findsNothing : findsOneWidget);
        expect(find.textContaining('最新版本：1.0.74'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await db.close();
        app.dispose();
      },
    );
  }
}
