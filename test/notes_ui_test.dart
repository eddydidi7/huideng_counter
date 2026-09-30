import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:huideng_counter/presentation/note_rich_content.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  for (final size in [const Size(360, 640), const Size(412, 915)]) {
    testWidgets('five tabs and note autosave on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      await app.set('language', 'zh');
      await tester.pumpWidget(HuidengApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      expect(find.byTooltip('搜索笔记与文章'), findsOneWidget);
      expect(find.byTooltip('笔记排序'), findsNothing);
      await tester.tap(find.byTooltip('搜索笔记与文章'));
      await tester.pumpAndSettle();
      expect(find.text('共享文章搜索尚未接入'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建笔记'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final richEditor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor),
      );
      expect(richEditor.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byType(quill.QuillSimpleToolbar), findsOneWidget);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 52);
      expect(tester.getSize(find.byType(quill.QuillSimpleToolbar)).height, 44);
      debugPrint(
        'NOTE_LAYOUT $size editor=${tester.getSize(find.byType(quill.QuillEditor)).height}',
      );
      final editorContext = tester.element(find.byType(quill.QuillEditor));
      final oldStatus = TextPainter(
        text: TextSpan(
          text: '0 字符 · 已本地保存',
          style: Theme.of(editorContext).textTheme.bodySmall,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final oldBodyHeight = size.height - 56 - 46 - oldStatus.height - 7;
      debugPrint(
        'NOTE_GAIN body=${tester.getSize(find.byType(quill.QuillEditor)).height - oldBodyHeight} oldStatus=${oldStatus.height}',
      );
      oldStatus.dispose();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byType(quill.QuillSimpleToolbar)).dy,
        lessThanOrEqualTo(size.height - 260),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '离线自动保存中文正文\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester
          .pump(); // Deliver asynchronous document change before debounce.
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(
        NoteRichContent.plainText(
          (await db.query('notes')).single['body'] as String,
        ),
        '离线自动保存中文正文',
      );
      tester.view.resetViewInsets();
      expect(find.byType(BackButton), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect((await db.query('notes')).single['title'], '');
      expect(find.text('离线自动保存中文正文'), findsWidgets);
      await tester.tap(find.text('离线自动保存中文正文').first);
      await tester.pumpAndSettle();
      expect(find.byType(quill.QuillEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('导出 Markdown'));
      expect(find.text('导出 Markdown').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('复制纯文本'));
      expect(find.text('复制纯文本').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('复制纯文本'))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(BackButton), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('笔记菜单'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, '收藏'), findsOneWidget);
      expect(find.text('收藏2'), findsNothing);
      expect(find.text('Favorites 2'), findsNothing);
      expect(find.byIcon(Icons.bookmark_border), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, '收藏'));
      await tester.pumpAndSettle();
      expect(find.text('暂无笔记'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      await tester.tap(find.byTooltip('笔记菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '所有笔记'));
      await tester.pumpAndSettle();
      expect(find.text('离线自动保存中文正文'), findsOneWidget);
      await tester.tap(find.byTooltip('笔记菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '不存在的关键词');
      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pumpAndSettle();
      expect(find.text('暂无笔记'), findsOneWidget);
      final deleteHint = MaterialLocalizations.of(
        tester.element(find.byType(InputChip)),
      ).deleteButtonTooltip;
      await tester.tap(find.byTooltip(deleteHint));
      await tester.pumpAndSettle();
      expect(find.text('离线自动保存中文正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final beforeHeight = tester
          .getSize(
            find
                .ancestor(
                  of: find.text('离线自动保存中文正文'),
                  matching: find.byType(ListTile),
                )
                .first,
          )
          .height;
      await tester.longPress(find.text('离线自动保存中文正文'));
      await tester.pumpAndSettle();
      expect(find.text('取消置顶'), findsNothing);
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect((await db.query('notes')).single['isPinned'], 1);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('离线自动保存中文正文'),
                    matching: find.byType(ListTile),
                  )
                  .first,
            )
            .height,
        beforeHeight,
      );
      await tester.longPress(find.text('离线自动保存中文正文'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();
      expect((await db.query('notes')).single['isPinned'], 0);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      final longBody = '批量置顶测试\n${'完整正文' * 1000}';
      await NotesRepository(db).save({'body': longBody});
      await tester.tap(find.byTooltip('笔记菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '所有笔记'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('离线自动保存中文正文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全选 / 取消全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('取消置顶'), findsOneWidget);
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(
        (await db.query('notes')).every((n) => n['isPinned'] == 1),
        isTrue,
      );
      expect(
        (await db.query('notes')).any((n) => n['body'] == longBody),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });
  }
}
