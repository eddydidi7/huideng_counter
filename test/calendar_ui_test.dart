import 'package:flutter/material.dart';
import 'package:huideng_counter/core/app_links_controller.dart';
import 'package:huideng_counter/domain/calendar_observance_config.dart';
import 'package:huideng_counter/domain/calendar_traditions.dart';
import 'app_links_test.dart' show FakeLinks;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/tibetan_calendar_page.dart';
import 'package:huideng_counter/data/local/tibetan_calendar.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  for (final size in [
    const Size(320, 640),
    const Size(360, 640),
    const Size(412, 915),
    const Size(480, 960),
  ]) {
    for (final fontScale in [1.0, 1.6]) {
      testWidgets(
        'offline month grid and details render without overflow at $size / $fontScale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final calendar = await tester.runAsync(() => TibetanCalendar.load());
          final db = await LocalDatabase.openAt(inMemoryDatabasePath);
          final app = AppController(SqliteCounterRepository(db));
          await app.set('language', 'zh');
          final remote = FakeLinks();
          final links = AppLinksController(remote);
          app.appLinks = links;
          await links.initialize();
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(fontScale)),
                child: TibetanCalendarPage(app: app, calendar: calendar!),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(GridView), findsOneWidget);
          final dateText = tester.widget<Text>(
            find.textContaining('藏历：').first,
          );
          expect(dateText.style!.fontSize, greaterThan(24));
          expect(find.text('藏历与日出'), findsOneWidget);
          expect(find.text('八关斋戒日出日中查询'), findsOneWidget);
          expect(find.textContaining('自动定位'), findsNothing);
          expect(find.text('离线藏历数据准备中'), findsNothing);
          await tester.tap(find.byTooltip('上一月'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('今天'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final config = CalendarObservanceConfig.defaults();
          final today = calendar.at(DateTime.now())!;
          final entry = Map<String, dynamic>.from(config['entries'][0]);
          entry.addAll({
            'zh': '后台实时殊胜日',
            'day': today['day'],
            'end_day': today['day'],
          });
          config['entries'] = [entry];
          final traditions = CalendarTraditions.defaults();
          traditions['observances'] = config;
          traditions['chinese_events'] = {
            TibetanCalendar.key(DateTime.now()): {
              'zh': '后台农历介绍',
              'en': 'Lunar description',
            },
          };
          remote.next = {'calendar_traditions': traditions};
          await links.refresh();
          await tester.pumpAndSettle();
          expect(
            find.textContaining('后台实时殊胜日', findRichText: true),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('calendar-chinese-events')),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            find.byKey(const ValueKey('calendar-chinese-lunar')),
            findsOneWidget,
          );
          expect(find.text('后台农历介绍'), findsOneWidget);
          await tester.drag(find.byType(ListView).first, const Offset(0, 1000));
          await tester.pumpAndSettle();
          config['entries'] = [];
          await links.refresh();
          await tester.pumpAndSettle();
          expect(
            find.textContaining('后台实时殊胜日', findRichText: true),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          links.dispose();
          app.dispose();
          await db.close();
        },
      );
    }
  }
}
