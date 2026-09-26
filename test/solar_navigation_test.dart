import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/presentation/solar_page.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets('calendar owns sunrise route and third tab is chat', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <MethodCall>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final app = AppController(SqliteCounterRepository(db));
    await app.set('language', 'zh');
    await tester.pumpWidget(HuidengApp(controller: app));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).height, 48);
    expect(
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(NavigationDestination).first,
                  matching: find.text('计数'),
                )
                .first,
          )
          .style
          ?.fontSize,
      17,
    );
    expect(
      tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label)
          .toList(),
      ['计数', '红书', '聊天', '笔记', '藏历'],
    );
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    await tester.tap(find.byTooltip('个人菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('个人主页'), findsOneWidget);
    await tester.tap(find.text('个人主页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('settings-account')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, isEmpty);
    await tester.tap(find.byType(NavigationDestination).at(4));
    // The bundled calendar is decoded on a real isolate; fake test time must
    // not wait for its loading spinner before exercising the independent link.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('calendar-sunrise-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, isEmpty);
    expect(find.byType(SolarPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('calendar-sunrise-entry')),
      findsOneWidget,
    );
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();

    await db.close();
  });
}
