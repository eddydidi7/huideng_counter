import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/presentation/forum_compose_page.dart';
import 'package:huideng_counter/presentation/forum_page.dart';
import 'support/forum_memory_draft.dart';
import 'forum_test.dart' show UnusedCounter, PublishingRepository;

void main() {
  for (final kind in ['image_text', 'article']) {
    testWidgets(
      'new $kind post splits title without changing draft or double-stripping on retry',
      (tester) async {
        final app = AppController(UnusedCounter());
        app.preferences['language'] = 'zh';
        final repo = PublishingRepository();
        final draft = MemoryDraft();
        const original = '适合作标题的开头。剩余正文不能重复删除。';
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              quill.FlutterQuillLocalizations.delegate,
            ],
            home: ForumComposePage(
              app: app,
              repository: repo,
              categories: forumCategories,
              initialKind: kind,
              initialBody: original,
              openDraft: (_) async => draft,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('forum-publish')));
        await tester.pumpAndSettle();
        expect(repo.requests.single['title'], '适合作标题的开头');
        expect(repo.requests.single['body'], '剩余正文不能重复删除。');
        final saved = (await draft.read('v1:new'))!;
        expect(saved['title'], '');
        if (kind == 'image_text') expect(saved['body'], original);
        if (kind == 'article') {
          expect(
            (repo.requests.single['rich_body'] as List).first['insert'],
            '剩余正文不能重复删除。\n',
          );
        }
        await tester.tap(find.byKey(const ValueKey('forum-publish')));
        await tester.pumpAndSettle();
        expect(repo.requests.length, 2);
        expect(repo.requests[1], repo.requests[0]);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        app.dispose();
      },
    );
  }
}
