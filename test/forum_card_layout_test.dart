import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/forum_card_layout.dart';
import 'package:huideng_counter/presentation/forum_card_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'pagination preserves ALL graphemes, fixed font, measured height and word boundaries',
    () {
      final text = List.filled(
        30,
        '愿众生平安🙏。 English words stay together!\n第二个段落，保持字号与顺序。\n',
      ).join();
      for (final size in [16.0, 20.0, 60.0]) {
        final style = ForumCardStyle()..size = size;
        final pages = paginateForumCard(text, style);
        expect(pages.length, greaterThan(1));
        expect(pages.join(), text);
        expect(style.size, size);
        for (var i = 0; i < pages.length; i++) {
          final painter = forumCardText(pages[i], style);
          expect(
            painter.height,
            lessThanOrEqualTo(480 - style.margin * 2 - 20 + .01),
          );
          painter.dispose();
          if (i + 1 < pages.length) {
            expect(
              RegExp(r'[A-Za-z]$').hasMatch(pages[i]) &&
                  RegExp(r'^[A-Za-z]').hasMatch(pages[i + 1]),
              isFalse,
            );
          }
        }
      }
    },
  );
  test('manual breaks and automatic reflow, paragraph preference', () {
    final s = ForumCardStyle();
    expect(paginateForumCard('第一页\f第二页', s), ['第一页', '第二页']);
    final long = List.filled(100, '同一个段落，不能漏字。').join();
    expect(paginateForumCard('短段落\n$long', s).first, '短段落\n');
    final small = paginateForumCard(long, s).length;
    s.size = 40;
    expect(paginateForumCard(long, s).length, greaterThan(small));
  });
  test('preset/custom foreground stays above WCAG AA contrast', () {
    for (final c in [...forumCardColors.values, const Color(0xff777777)]) {
      final s = ForumCardStyle()
        ..background = c
        ..requestedText = c;
      final a = c.computeLuminance(), b = s.textColor.computeLuminance();
      expect(
        ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
        greaterThanOrEqualTo(4.5),
      );
      expect(ForumCardStyle.fromJson(s.toJson()).toJson(), s.toJson());
    }
  });
  test('every template x colour keeps readable text and fits the card', () {
    final text = List.filled(40, '书摘与札记，闻思修三慧。Clear words stay whole.\n').join();
    for (final template in forumCardTemplates) {
      for (final base in [
        ...forumCardColors.values,
        const Color(0xff777777),
        const Color(0xff2255aa),
      ]) {
        final s = ForumCardStyle()
          ..template = template.id
          ..background = base;
        final p = s.palette;
        final surface = template.onPanel ? p.panel : p.background;
        expect(
          forumCardContrast(s.textColor, surface),
          greaterThanOrEqualTo(4.5),
          reason: '${template.id} on $base',
        );
        expect(
          forumCardContrast(p.muted, p.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          forumCardContrast(p.accent, p.background) >= 3 || p.accent == p.text,
          isTrue,
        );
        final area = forumCardTextArea(s);
        expect(area.left, greaterThanOrEqualTo(0));
        expect(area.bottom, lessThanOrEqualTo(forumCardHeight));
        final pages = paginateForumCard(text, s);
        expect(pages.join(), text);
        for (final page in pages) {
          final painter = forumCardText(page, s);
          expect(painter.height, lessThanOrEqualTo(area.height + .01));
          expect(painter.width, lessThanOrEqualTo(area.width + .01));
          painter.dispose();
        }
      }
    }
  });

  test('same template, different colours: only the palette changes', () {
    final yellow = ForumCardStyle()
      ..template = '书摘'
      ..background = forumCardColors['淡黄']!;
    final black = ForumCardStyle.fromJson({
      ...yellow.toJson(),
      'background': forumCardColors['黑色']!.toARGB32(),
    });
    expect(black.template, '书摘');
    expect(black.palette.dark, isTrue);
    expect(yellow.palette.dark, isFalse);
    expect(black.palette.text, isNot(yellow.palette.text));
    expect(forumCardTextArea(black), forumCardTextArea(yellow));
  });

  test('a newly registered template works with every colour', () async {
    final added = ForumCardTemplate(
      id: '测试模板',
      inset: const EdgeInsets.all(12),
      front: (c, p, t) => c.drawCircle(Offset.zero, 6, Paint()..color = p.accent),
    );
    forumCardTemplates.add(added);
    addTearDown(() => forumCardTemplates.remove(added));
    for (final base in forumCardColors.values) {
      final s = ForumCardStyle.fromJson({
        'template': '测试模板',
        'background': base.toARGB32(),
        'weight': '粗体',
      });
      expect(s.template, '测试模板');
      expect(s.weight, '粗体');
      final png = await renderForumCardPage('新模板', s, 0, 1);
      expect(png, isNotEmpty);
    }
    expect(ForumCardStyle.fromJson({'template': 'unknown'}).template, '基础');
  });

  test('every page exports an identically sized PNG', () async {
    final s = ForumCardStyle()..size = 60;
    final pages = paginateForumCard('甲\f乙', s);
    for (var i = 0; i < pages.length; i++) {
      final codec = await ui.instantiateImageCodec(
        await renderForumCardPage(pages[i], s, i, pages.length),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1080);
      expect(frame.image.height, 1440);
      frame.image.dispose();
      codec.dispose();
    }
  });
  testWidgets(
    'small phone: page selection and manual break persist, no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ForumCardEditor(
            initial: {'text': '甲\f乙'},
            onDraft: (v) async {
              saved = v;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('从这里分页 / 下一页'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('从这里分页 / 下一页'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((saved!['text'] as String).split('\f').length, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('swipe preview pages; pick template and colour separately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ForumCardEditor(
          initial: {'text': '第一页\f第二页\f第三页'},
          onDraft: (v) async => saved = v,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey('card-preview-pages')),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('card-template-书摘')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('card-template-书摘')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('card-color-黑色')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('card-color-黑色')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(saved!['style']['template'], '书摘');
    expect(saved!['style']['background'], forumCardColors['黑色']!.toARGB32());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'custom color dialog updates preview without disposed-controller errors',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ForumCardEditor(
            initial: {'text': '文字颜色预览'},
            onDraft: (v) async {
              saved = v;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('自定义颜色'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('自定义颜色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义颜色'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'HEX，例如 E3F1DF'),
        '121212',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      // Drafts are saved after a 250 ms debounce.
      await tester.pump(const Duration(milliseconds: 300));
      expect(saved!['style']['background'], 0xff121212);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
