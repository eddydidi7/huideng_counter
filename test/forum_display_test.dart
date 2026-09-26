import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/post_display.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/presentation/forum_page.dart';
import 'package:huideng_counter/data/repositories/forum_repository.dart';
import 'forum_test.dart' show UnusedCounter, Remote, MemoryCache;

void main() {
  test(
    'display titles preserve user titles and original excerpts without mutation',
    () {
      for (final title in ['真实标题', '文字分享', '图片分享', '未命名']) {
        expect(getPostDisplayTitle({'title': title, 'body': '原文'}), title);
      }
      expect(
        getPostDisplayTitle({'body': '  \n 第一段\n\n 第二段   后面'}),
        '第一段 第二段 后面',
      );
      expect(
        getPostDisplayTitle({
          'body': '短句',
          'image_urls': ['image'],
        }),
        '短句',
      );
      expect(
        getPostDisplayTitle({
          'image_urls': ['image'],
        }),
        '',
      );
      final post = {'title': '', 'body': '🙏' * 40};
      final original = Map.of(post);
      expect(getPostDisplayTitle(post), '${'🙏' * 28}……');
      expect(post, original);
    },
  );
  for (final width in [148.0, 344.0, 760.0]) {
    testWidgets('compact footer long name and large counts width=$width', (
      tester,
    ) async {
      final app = AppController(UnusedCounter());
      app.preferences['language']='zh';
      var likes = 0, opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ForumPostCard(
                  app: app,
                  row: {
                    'title': '',
                    'body': '无标题原文',
                    'author_name': '非常非常长的学友昵称',
                    'like_count': 123456789,
                    'reply_count': 12345678,
                  },
                  listMode: width > 200,
                  onLike: () => likes++,
                  onTap: () => opens++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final like = find.byTooltip('点赞 123456789'),
          reply = find.byTooltip('评论 12345678');
      expect(tester.getCenter(like).dy, tester.getCenter(reply).dy);
      expect(tester.getSize(like).height, greaterThanOrEqualTo(44));
      await tester.tap(like);
      await tester.tap(reply);
      expect(likes, 1);
      expect(opens, 1);
      app.dispose();
    });
  }
  testWidgets('existing layout button opens choices and persists locally', (
    tester,
  ) async {
    final app = AppController(UnusedCounter());
      app.preferences['language']='zh';
    await tester.pumpWidget(
      MaterialApp(
        home: ForumPage(
          app: app,
          repository: ForumRepository(Remote(), MemoryCache()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('版面设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单列'));
    await tester.pumpAndSettle();
    expect(app.preferences['forum_layout_mode'], 'list');
    expect(
      tester
          .widgetList<ForumPostCard>(find.byType(ForumPostCard))
          .every((c) => c.listMode),
      true,
    );
    expect(find.byType(ForumPostCard).evaluate().length, lessThan(21));
    await tester.tap(find.byTooltip('版面设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('双列'));
    await tester.pumpAndSettle();
    expect(app.preferences['forum_layout_mode'], 'grid');
    expect(tester.takeException(), isNull);
    app.dispose();
  });
}
