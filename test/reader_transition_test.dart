import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/presentation/note_reader_page.dart';
import 'package:huideng_counter/presentation/shared_rich_editor.dart';

void main() {
  testWidgets('Quill visible position ignores a stale caret at the start', (
    tester,
  ) async {
    final editorKey = GlobalKey<quill.EditorState>();
    final viewportKey = GlobalKey();
    final scroll = ScrollController();
    final controller = quill.QuillController(
      document: quill.Document.fromJson([
        {'insert': '${List.generate(100, (i) => '正文段落 $i').join('\n')}\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          quill.FlutterQuillLocalizations.delegate,
        ],
        home: Scaffold(
          body: SharedRichEditor(
            key: viewportKey,
            controller: controller,
            scrollController: scroll,
            config: quill.QuillEditorConfig(
              editorKey: editorKey,
              expands: true,
            ),
          ),
        ),
      ),
    );
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pump();
    final offset = visibleNoteOffset(editorKey, viewportKey);
    expect(offset, greaterThan(200));
    expect(controller.selection.baseOffset, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    scroll.dispose();
  });

  testWidgets('long single paragraph is positioned before its first paint', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const native = MethodChannel('org.huideng.counter/reader');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (_) async => null,
    );
    final body = '长段落内容' * 1000;
    final prepared = await PreparedNoteReader.load(body);
    await tester.pumpWidget(
      MaterialApp(
        home: NoteReaderPage(
          body: body,
          noteId: 'long',
          scope: 'test',
          title: '测试',
          prepared: prepared,
          documentOffset: 2500,
        ),
      ),
    );
    final rich = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == body,
    );
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final caret = paragraph.localToGlobal(
      paragraph.getOffsetForCaret(const TextPosition(offset: 2500), Rect.zero),
    );
    expect(caret.dy, inInclusiveRange(-1, 40));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      null,
    );
  });

  testWidgets(
    'prepared first frame has saved theme and current text without waiting for TTS',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader.preferences.v1.test': jsonEncode({'theme': 'light'}),
        'reader.position.v1.test.note': jsonEncode({
          'read': {'index': 0},
        }),
      });
      final snapshot = Completer<Object?>();
      const native = MethodChannel('org.huideng.counter/reader');
      final platformCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (call.method == 'snapshot') return snapshot.future;
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call.method);
          return null;
        },
      );
      final body = List.generate(100, (i) => '段落 $i：已加载的正文。').join('\n');
      final prepared = await PreparedNoteReader.load(body);
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            body: body,
            noteId: 'note',
            scope: 'test',
            title: '测试',
            prepared: prepared,
            documentOffset: body.indexOf('段落 50'),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('段落 50', findRichText: true), findsWidgets);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xfff6f6f4),
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('reader-progress')))
            .value,
        inInclusiveRange(.45, .55),
      );
      snapshot.complete(null);
      await tester.pumpAndSettle();
      expect(
        platformCalls,
        isNot(contains('SystemChrome.setEnabledSystemUIMode')),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );

  testWidgets(
    'mode round trip retains underlying route and scroll, exits native once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const native = MethodChannel('org.huideng.counter/reader');
      var exits = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (call.method == 'exit') exits++;
        return null;
      });
      final scroll = ScrollController(initialScrollOffset: 1500);
      final sourceKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              key: sourceKey,
              appBar: AppBar(
                actions: [
                  TextButton(
                    onPressed: () => openNoteReader(
                      context,
                      body: '开头\n中间\n末尾',
                      noteId: 'note',
                      scope: 'test',
                      title: '测试',
                      documentOffset: 3,
                    ),
                    child: const Text('进入阅读'),
                  ),
                ],
              ),
              body: ListView.builder(
                controller: scroll,
                itemExtent: 60,
                itemCount: 100,
                itemBuilder: (_, i) => Text('原页面 $i'),
              ),
            ),
          ),
        ),
      );
      final original = sourceKey.currentContext;
      await tester.tap(find.text('进入阅读'));
      await tester.pumpAndSettle();
      expect(sourceKey.currentContext, same(original));
      expect(scroll.offset, 1500);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NoteReaderPage), findsNothing);
      expect(sourceKey.currentContext, same(original));
      expect(scroll.offset, 1500);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      );
    },
  );
}
