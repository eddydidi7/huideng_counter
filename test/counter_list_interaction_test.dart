import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/presentation/home_page.dart';

class ListRepository extends Fake implements CounterRepository {
  List<String> order = ['a', 'b', 'c', 'd'];
  int reorders = 0;
  @override
  Future<List<CounterProject>> projects() async => order
      .map(
        (id) => CounterProject({
          'id': id,
          'name': '计数项目$id',
          'total': 123,
          'position': order.indexOf(id),
          'lastRecitedAt': '2026-09-17T12:30:00',
        }),
      )
      .toList();
  @override
  Future<Map<String, String>> settings() async => {'language': 'zh'};
  @override
  Future<void> reorder(List<String> ids) async {
    order = [...ids];
    reorders++;
  }
}

void main() {
  testWidgets('more menu opens and drag handle responds at its outer edge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 835));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = ListRepository();
    final app = AppController(repository);
    await app.reload();
    await tester.pumpWidget(MaterialApp(home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(1.4)), child: HomePage(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsNothing);
    // Grab outside the painted 24dp glyph, inside the 44×32dp control.
    final handle = find
        .byWidgetPredicate((w) => w.runtimeType == ReorderableDragStartListener)
        .first;
    final gesture = await tester.startGesture(
      tester.getTopLeft(handle) + const Offset(2, 2),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 240));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(repository.reorders, 1);
    expect(repository.order.first, 'b');
    expect(repository.order.toSet(), {'a', 'b', 'c', 'd'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}

