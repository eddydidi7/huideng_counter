import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/chat_message_style.dart';

void main() {
  test('time separators use five minute gaps and calendar dates', () {
    expect(showChatTime('2026-09-17T01:00:00Z', null), isTrue);
    expect(
      showChatTime('2026-09-17T01:04:59Z', '2026-09-17T01:00:00Z'),
      isFalse,
    );
    expect(
      showChatTime('2026-09-17T01:05:00Z', '2026-09-17T01:00:00Z'),
      isTrue,
    );
    expect(showChatTime('invalid', null), isFalse);
    expect(
      chatTimeLabel(
        DateTime(2026, 9, 16, 13, 39),
        DateTime(2026, 9, 17),
        english: false,
      ),
      '昨天 13:39',
    );
  });
  for (final brightness in Brightness.values) {
    testWidgets('bubble text and voice buttons readable in $brightness', (
      tester,
    ) async {
      for (final mine in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: ChatMessageBubble(
                mine: mine,
                child: Builder(
                  builder: (context) {
                    final card = context.findAncestorWidgetOfExactType<Card>()!;
                    final ink = Theme.of(context).textTheme.bodyMedium!.color!;
                    final a = card.color!.computeLuminance(),
                        b = ink.computeLuminance();
                    final ratio =
                        ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
                    expect(ratio, greaterThanOrEqualTo(4.5));
                    expect(
                      Theme.of(
                        context,
                      ).textButtonTheme.style!.foregroundColor!.resolve({}),
                      ink,
                    );
                    return const Text('测试消息');
                  },
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });
  }
}
