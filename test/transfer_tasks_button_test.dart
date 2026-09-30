import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/direct_transfer_page.dart';

void main() {
  testWidgets('empty task queue consumes no toolbar space', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [TransferTasksButton(count: 0, onPressed: () {})],
          ),
        ),
      ),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(tester.getSize(find.byType(TransferTasksButton)).width, 0);
  });

  testWidgets('compact badge opens tasks and hides when queue clears', (
    tester,
  ) async {
    var opened = false;
    Widget app(int count) => MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            TransferTasksButton(count: count, onPressed: () => opened = true),
          ],
        ),
      ),
    );
    await tester.pumpWidget(app(2));
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byTooltip('文件传输（2）'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app(0));
    expect(find.byType(Badge), findsNothing);
  });
}
