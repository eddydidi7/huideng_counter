import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/domain/note_reader.dart';
import 'package:huideng_counter/presentation/note_reader_page.dart';

void main() {
  test(
    'legacy and rich text retain original content; anchor follows inserted paragraphs',
    () {
      final body = jsonEncode([
        {
          'insert': '第一段',
          'attributes': {'bold': true},
        },
        {'insert': '\n第二段\n'},
        {
          'insert': {'image': 'data:image/png;base64,AA=='},
        },
        {'insert': '\n'},
      ]);
      final p = readerParagraphs(body);
      expect(p[0].text, '第一段');
      expect(p[1].text, '第二段');
      expect(p[2].runs.single['insert'], isA<Map>());
      final newer = readerParagraphs('新增段\n第一段\n第二段\n');
      expect(restoreReaderAnchor(newer, {'index': 1, 'anchor': '第二段'}), 2);
      expect(readerParagraphs('普通笔记').single.text, '普通笔记');
      final long = '${'字' * 899}😀末尾';
      final end = readerSpeechEnd(long, 0);
      expect(end, 899);
      expect(long.substring(end), '😀末尾');
    },
  );
  test('all 28 rates normalize to exact tenth display', () {
    for (var i = 3; i <= 30; i++) {
      expect(
        normalizeReaderRate(i / 10 + .000000001).toStringAsFixed(1),
        (i / 10).toStringAsFixed(1),
      );
    }
  });
  testWidgets(
    'reattach session, rate persistence and ordinary dispose never stop speech',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader.preferences.v1.test': jsonEncode({'rate': 1.4, 'repeat': true}),
      });
      var playing = false;
      var rate = 1.4;
      final calls = <MethodCall>[];
      const channel = MethodChannel('org.huideng.counter/reader');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'snapshot') {
          return {
            'noteId': 'immutable',
            'active': true,
            'playing': playing,
            'index': 1,
            'offset': 0,
            'rate': rate,
          };
        }
        if (call.method == 'control') {
          final data = call.arguments as Map;
          if (data['action'] == 'resume') playing = true;
          if (data['action'] == 'pause' || data['action'] == 'stop') {
            playing = false;
          }
          if (data['rate'] != null) rate = data['rate'];
        }
        return true;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: NoteReaderPage(
            body: '第一段\n第二段',
            noteId: 'immutable',
            scope: 'test',
            title: '阅读测试',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('1.4x'), findsOneWidget);
      await tester.tap(find.byTooltip('播放 / 继续'));
      await tester.pumpAndSettle();
      expect(playing, true);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(playing, false);
      final slider = tester
          .widgetList<Slider>(find.byType(Slider))
          .firstWhere((s) => s.min == .3);
      expect(slider.max, 3);
      expect(slider.divisions, 27);
      slider.onChanged!(1.7);
      await tester.pumpAndSettle();
      expect(find.text('1.7x'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('reader.preferences.v1.test')!)['rate'],
        1.7,
      );
      await tester.tap(find.byTooltip('播放 / 继续'));
      await tester.pumpAndSettle();
      final stops = calls
          .where(
            (c) =>
                c.method == 'control' &&
                (c.arguments as Map)['action'] == 'stop',
          )
          .length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(playing, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        calls
            .where(
              (c) =>
                  c.method == 'control' &&
                  (c.arguments as Map)['action'] == 'stop',
            )
            .length,
        stops,
      );
      expect(playing, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );
}
