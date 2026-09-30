import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/stepper_slider.dart';

void main() {
  testWidgets('tapping + and - nudges by step and clamps at the bounds', (
    tester,
  ) async {
    var value = 18.0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: StepperSlider(
              value: value,
              min: 8,
              max: 40,
              step: 1,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(value, 19);
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();
    expect(value, 17);
  });

  testWidgets('minus is disabled at min, plus is disabled at max', (
    tester,
  ) async {
    Future<void> pump(double v) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StepperSlider(
            value: v,
            min: 0,
            max: 1,
            step: .1,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await pump(0);
    expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove)).onPressed,
      isNull,
    );
    await pump(1);
    expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add)).onPressed,
      isNull,
    );
  });

  testWidgets('a nudge calls onChangeStart then onChanged then onChangeEnd', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StepperSlider(
            value: .5,
            min: 0,
            max: 1,
            step: .1,
            onChangeStart: (_) => calls.add('start'),
            onChanged: (_) => calls.add('changed'),
            onChangeEnd: (_) => calls.add('end'),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(calls, ['start', 'changed', 'end']);
  });

  testWidgets('enabled: false disables both buttons and the slider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StepperSlider(
            value: .5,
            min: 0,
            max: 1,
            step: .1,
            enabled: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add)).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove)).onPressed,
      isNull,
    );
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });
}
