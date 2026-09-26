import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/jieyuan_fields.dart';

void main() {
  testWidgets(
    'compact item editor retains values and exposes status and remote currencies',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var item = {
        ...newJieyuan(),
        'type': 'paid',
        'price': '20',
        'currency': 'NZD',
        'region': '奥克兰',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => JieyuanFields(
                  value: item,
                  editing: true,
                  currencies: const ['CNY', 'NZD', 'AUD', 'USD', 'EUR'],
                  onChanged: (v) => setState(() => item = v),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('价格'), findsOneWidget);
      expect(find.text('状态'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('quantity')), '3');
      await tester.pump();
      expect(item['quantity'], 3);
      expect(item['price'], '20');
      expect(jieyuanSummary(item), contains('NZD 20'));
      expect(tester.takeException(), isNull);
    },
  );
  test('text-only requests do not require a price', () {
    final j = {...newJieyuan(), 'type': 'wanted'};
    expect(jieyuanSummary(j), contains('求结缘'));
    expect(j['status'], 'available');
  });
}
