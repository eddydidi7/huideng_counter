import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/adaptive_action_bar.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('reader actions scale independently and follow $brightness', (
      tester,
    ) async {
      var reads = 0, done = 0, menus = 0;
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AdaptiveActionBar(
              menuIndex: 1,
              actions: [
                BarAction(
                  '阅读模式',
                  () => reads++,
                  icon: Icons.chrome_reader_mode_outlined,
                  visualScale: .85,
                ),
                BarAction('完成', () => done++, visualScale: .85),
                BarAction('其他', () {}),
              ],
              menu: IconButton(
                onPressed: () => menus++,
                icon: Icon(
                  Icons.more_horiz,
                  size: 24 * 1.12,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('阅读模式'), findsNothing);
      final reader = tester.widgetList<IconButton>(find.byType(IconButton))
          .firstWhere((button) => button.tooltip == '阅读模式');
      expect(reader.iconSize, closeTo(28 * .85, .001));
      expect(reader.color, theme.colorScheme.onSurface);
      final buttons = tester
          .widgetList<TextButton>(find.byType(TextButton))
          .toList();
      expect(
        buttons[0].style!.textStyle!.resolve({})!.fontSize,
        closeTo(28 * .85, .001),
      );
      expect(buttons[1].style!.textStyle!.resolve({})!.fontSize, 28);
      expect(
        buttons[0].style!.foregroundColor!.resolve({}),
        theme.colorScheme.onSurface,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.more_horiz)).size,
        closeTo(26.88, .001),
      );
      expect(
        tester.getSize(find.byTooltip('阅读模式')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('阅读模式'));
      await tester.tap(find.text('完成'));
      await tester.tap(find.byIcon(Icons.more_horiz));
      expect([reads, done, menus], [1, 1, 1]);
      expect(tester.takeException(), isNull);
    });
  }
}
