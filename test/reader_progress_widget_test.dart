import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/presentation/note_reader_page.dart';
import 'package:huideng_counter/services/windows_reader_speech.dart';

void main() {
  for (final rate in [.3, 1.0, 3.0]) {
    testWidgets(
      'Android rate $rate stays on the reported range and centers its actual line',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        const channel = MethodChannel('org.huideng.counter/reader');
        var offset = 500;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'snapshot') {
              return {
                'active': true,
                'playing': true,
                'index': 0,
                'offset': offset,
                'rangeEnd': offset + 2,
                'rate': rate,
              };
            }
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: NoteReaderPage(
              body: '甲乙' * 1000,
              noteId: 'android-$rate',
              scope: 'test',
              title: '同步测试',
            ),
          ),
        );
        await tester.pumpAndSettle();
        Slider progress() => tester.widget<Slider>(
          find.byKey(const ValueKey('reader-progress')),
        );
        expect(progress().value, closeTo(.25, .002));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(progress().value, closeTo(.25, .002));
        offset = 800;
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(progress().value, closeTo(.4, .002));
        final rich = find.descendant(
          of: find.byKey(const ValueKey('reader-paragraph-0')),
          matching: find.byType(RichText),
        );
        final text = tester.renderObject<RenderParagraph>(rich);
        final viewport = RenderAbstractViewport.of(text) as RenderBox;
        final y = text
            .localToGlobal(
              text.getOffsetForCaret(
                const TextPosition(offset: 800),
                Rect.zero,
              ),
              ancestor: viewport,
            )
            .dy;
        expect(y / viewport.size.height, closeTo(.45, .03));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    'Windows reading seek 50 to 70 percent restarts speech and follows word progress',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      var wordOffset = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsReaderSpeech.channel,
        (call) async {
          calls.add(call);
          if (call.method == 'voices') {
            return [
              {
                'id': 'real',
                'name': 'Chinese system voice',
                'language': 'zh-CN',
              },
            ];
          }
          if (call.method == 'status') {
            return {'done': false, 'offset': wordOffset};
          }
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          WindowsReaderSpeech.channel,
          null,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            body: '甲' * 1000,
            noteId: 'seek',
            scope: 'test',
            title: '测试',
          ),
        ),
      );
      await tester.pumpAndSettle();
      Slider progress() =>
          tester.widget<Slider>(find.byKey(const ValueKey('reader-progress')));
      progress().onChangeStart!(.5);
      progress().onChanged!(.5);
      progress().onChangeEnd!(.5);
      await tester.pumpAndSettle();
      expect(progress().value, closeTo(.5, .002));
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放 / 继续'));
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((c) => c.method == 'speak').arguments as Map)['text'],
        '甲' * 500,
      );
      progress().onChangeStart!(.7);
      progress().onChanged!(.7);
      progress().onChangeEnd!(.7);
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((c) => c.method == 'speak').arguments as Map)['text'],
        '甲' * 300,
      );
      wordOffset = 40;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(progress().value, closeTo(.74, .002));
      await tester.tap(find.byTooltip('隐藏控制栏'));
      await tester.pumpAndSettle();
      final rich = find.descendant(
        of: find.byKey(const ValueKey('reader-paragraph-0')),
        matching: find.byType(RichText),
      );
      double spokenY() {
        final text = tester.renderObject<RenderParagraph>(rich);
        final viewport = RenderAbstractViewport.of(text) as RenderBox;
        return text
                .localToGlobal(
                  text.getOffsetForCaret(
                    const TextPosition(offset: 740),
                    Rect.zero,
                  ),
                  ancestor: viewport,
                )
                .dy /
            viewport.size.height;
      }

      expect(spokenY(), closeTo(.45, .03));
      final rendered = tester.widget<RichText>(rich).text as TextSpan;
      final highlighted = <String>[];
      void collect(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.backgroundColor != null) {
            highlighted.add(span.text ?? '');
          }
          for (final child in span.children ?? <InlineSpan>[]) {
            collect(child);
          }
        }
      }

      collect(rendered);
      expect(highlighted.join(), '甲');
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 140));
      await tester.pumpAndSettle();
      final manualPosition = controller.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offset, closeTo(manualPosition, 1));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(spokenY(), closeTo(.45, .03));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await WindowsReaderSpeech.instance.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
