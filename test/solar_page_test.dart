import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/domain/solar_times.dart';
import 'package:huideng_counter/presentation/solar_page.dart';
import 'package:huideng_counter/services/solar_location_service.dart';
import 'package:huideng_counter/domain/solar_cities.dart';

class WaitingLocation extends SolarLocationService {
  WaitingLocation(this.cached);
  final SolarLocation? cached;
  final pending = Completer<SolarLocation>();
  @override
  Future<SolarLocation?> load() async => cached;
  @override
  Future<SolarLocation> refresh({
    SolarLocation? previous,
    bool explicit = false,
  }) => pending.future;
}

class FailedNameLocation extends WaitingLocation {
  FailedNameLocation() : super(null);
  int lookups = 0;
  @override
  Future<String> resolveName(SolarLocation fix) async {
    lookups++;
    return '';
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets(
    'manual city works during pending GPS, persists, and rejects late GPS failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.set('language', 'zh');
      final source = WaitingLocation(null);
      await tester.pumpWidget(
        MaterialApp(
          home: SolarPage(app: app, locationService: source),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择地区'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('solar-city-search')),
        'Lhasa',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('拉萨 · 中国'));
      await tester.pumpAndSettle();
      expect(find.text('Asia/Shanghai'), findsOneWidget);
      expect(find.byKey(const ValueKey('solar-noon')), findsOneWidget);
      expect((await SolarLocationService().load())!.manual, true);
      source.pending.completeError(const SolarLocationFailure('denied'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('solar-location-error')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final restored = WaitingLocation(
        findSolarCities('Lhasa').single.location(english: false),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SolarPage(app: app, locationService: restored),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('拉萨 · 中国'), findsOneWidget);
      expect(find.text('正在获取当前位置…'), findsNothing);
      await tester.tap(find.text('使用当前位置'));
      await tester.pump();
      expect(find.text('正在获取当前位置…'), findsOneWidget);
      restored.pending.complete(
        findSolarCities('Auckland').single.location(english: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('奥克兰 · 新西兰'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
      await db.close();
    },
  );
  testWidgets(
    'fresh GPS renders solar times despite failed names and automatically retries',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.set('language', 'zh');
      final source = FailedNameLocation();
      await tester.pumpWidget(
        MaterialApp(
          home: SolarPage(app: app, locationService: source),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      source.pending.complete(
        SolarLocation(
          latitude: 31.2304,
          longitude: 121.4737,
          name: '',
          updatedAt: DateTime.now(),
          savedOffsetMinutes: 480,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('solar-noon')), findsOneWidget);
      expect(source.lookups, 1);
      await tester.pump(const Duration(seconds: 11));
      expect(source.lookups, 2);
      expect(find.byKey(const ValueKey('solar-noon')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
  for (final cache in [true, false]) {
    testWidgets('GPS unresolved then denied; cached=$cache', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.set('language', 'zh');
      final source = WaitingLocation(
        cache
            ? SolarLocation(
                latitude: 31.2304,
                longitude: 121.4737,
                name: '上海',
                updatedAt: DateTime.now(),
                savedOffsetMinutes: 480,
                timezoneId: 'Asia/Shanghai',
              )
            : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SolarPage(app: app, locationService: source),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('solar-noon')),
        cache ? findsOneWidget : findsNothing,
      );
      expect(find.text('正在获取当前位置…'), findsOneWidget);
      source.pending.completeError(const SolarLocationFailure('denied'));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('solar-location-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('solar-noon')),
        cache ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });
  }
}
