import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/presentation/large_note_editor.dart';
import 'package:huideng_counter/presentation/note_reader_page.dart';

void main() {
  testWidgets(
    'large document renders bounded editor and reader widgets on narrow phone',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      final body = '闻思修行法' * 1000000;
      final note = <String, Object?>{
        'id': 'large',
        'body': body,
        'title': '长文',
      };
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            quill.FlutterQuillLocalizations.delegate,
          ],
          home: LargeNoteEditor(
            app: app,
            repository: NotesRepository(db),
            note: note,
          ),
        ),
      );
      for (
        var i = 0;
        i < 60 && find.byType(quill.QuillEditor).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      final editor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor),
      );
      expect(editor.controller.document.length, lessThanOrEqualTo(16001));
      expect(find.byTooltip('阅读模式'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 2 /'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('org.huideng.counter/reader');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'snapshot' ? <String, dynamic>{} : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            body: body,
            noteId: 'large',
            scope: 'local',
            title: '长文',
          ),
        ),
      );
      for (
        var i = 0;
        i < 60 && find.byType(CustomScrollView).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(RichText).evaluate().length, lessThan(60));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      app.dispose();
      await db.close();
    },
  );
}
