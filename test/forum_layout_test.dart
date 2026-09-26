import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/presentation/forum_page.dart';
import 'package:huideng_counter/data/repositories/forum_repository.dart';
import 'forum_test.dart' show UnusedCounter, Remote, MemoryCache;

void main() {
  for (final list in [false, true]) {
    for (final image in [false, true]) {
      testWidgets('card list=$list image=$image has no empty image slot', (
        tester,
      ) async {
        final app = AppController(UnusedCounter());
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: SizedBox(
                width: list ? 344 : 168,
                child: ForumPostCard(
                  app: app,
                  row: {
                    'id': 'test',
                    'title': '修行心得',
                    'body': '正文摘要',
                    'image_urls': image
                        ? ['https://example.com/picture.jpg']
                        : [],
                  },
                  listMode: list,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Image), image ? findsOneWidget : findsNothing);
        expect(
          find.byType(AspectRatio),
          image ? findsOneWidget : findsNothing,
        );
        if (image && list) {
          expect(tester.getSize(find.byType(Image)).width, greaterThan(300));
        }
        expect(tester.takeException(), isNull);
        app.dispose();
      });
    }
  }
  testWidgets('opening restores saved list preference', (tester) async {
    final app = AppController(UnusedCounter());
    app.preferences['forum_layout_mode'] = 'list';
    await tester.pumpWidget(
      MaterialApp(
        home: ForumPage(
          app: app,
          repository: ForumRepository(Remote(), MemoryCache()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ForumPostCard>(find.byType(ForumPostCard).first).listMode,
      isTrue,
    );
    app.dispose();
  });
}
