import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/core/cloud_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/local/account_database_manager.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/main.dart';

class HeldRepository extends SqliteCounterRepository {
  final gate = Completer<void>();
  final ended = Completer<void>();
  @override
  Future<void> endSession(String sessionId) async {
    await super.endSession(sessionId);
    if (!ended.isCompleted) ended.complete();
  }

  HeldRepository(super.db);
  @override
  Future<int> increment(
    String sessionId, {
    CountSource source = CountSource.screen,
    DateTime? occurredAt,
  }) async {
    await gate.future;
    return super.increment(sessionId, source: source, occurredAt: occurredAt);
  }
}

class SwitchingLogin extends CloudController {
  final finished = Completer<void>();
  SwitchingLogin(super.app, super.databases);
  @override
  Future<void> signIn(String address, String password) async {
    app.scopeId = 'signed-in-test';
    app.notifyListeners();
    await finished.future;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  testWidgets(
    'successful sign-in may dispose the login form before returning',
    (tester) async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      final cloud = SwitchingLogin(
        app,
        AccountDatabaseManager(Directory.systemTemp, db),
      );
      cloud.ready = true;
      cloud.status = 'guest';
      app.cloud = cloud;
      await app.set('language', 'en');
      final messages = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account and sync'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      cloud.finished.complete();
      await tester.pumpAndSettle();
      debugPrint = previousPrint;
      expect(app.scopeId, 'signed-in-test');
      expect(
        messages.where((m) => m.contains('account_operation_error')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      cloud.dispose();
      app.dispose();
      await db.close();
    },
  );
  testWidgets('account sign-in renders in both languages on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await LocalDatabase.openAt(inMemoryDatabasePath);
    final app = AppController(SqliteCounterRepository(db));
    final cloud = CloudController(
      app,
      AccountDatabaseManager(Directory.systemTemp, db),
    );
    cloud.ready = true;
    cloud.status = 'guest';
    app.cloud = cloud;
    await app.reload();
    await app.set('language', 'en');
    await tester.pumpWidget(HuidengApp(controller: app));
    await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account and sync'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Guest mode · Stored on this device'), findsOneWidget);
    await app.set('language', 'zh');
    await tester.pumpAndSettle();
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('注册账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    cloud.dispose();
    app.dispose();
    await db.close();
  });

  testWidgets(
    'a tap accepted before an account switch remains in the original database',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('huideng_account_ui_');
      final db = (await tester.runAsync(
        () => LocalDatabase.openAt('${dir.path}/original.sqlite'),
      ))!;
      final original = HeldRepository(db);
      await original.saveProject('Original account', null);
      final app = AppController(original);
      await app.reload();
      await app.set('language', 'en');
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.tap(find.text('Original account'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('counter-image')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      final nextDb = (await tester.runAsync(
        () => LocalDatabase.openAt('${dir.path}/next.sqlite'),
      ))!;
      final next = SqliteCounterRepository(nextDb);
      await next.saveProject('New account', null);
      await app.switchRepository(next, 'new-account');
      await tester.pumpAndSettle();
      original.gate.complete();
      for (
        var attempt = 0;
        attempt < 100 && !original.ended.isCompleted;
        attempt++
      ) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(
        original.ended.isCompleted,
        isTrue,
        reason: 'Queued count and session close must finish',
      );
      await tester.pumpAndSettle();
      expect((await original.projects()).single.total, 1);
      expect((await next.projects()).single.total, 0);
      expect((await db.query('sessions')).single['endAt'], isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
      await nextDb.close();
      if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path) ||
          !dir.path.contains('huideng_account_ui_')) {
        throw StateError('Unsafe temp path');
      }
      dir.deleteSync(recursive: true);
    },
  );
}
