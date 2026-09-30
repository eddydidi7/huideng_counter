import 'support/forum_memory_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/remote/forum_remote.dart';
import 'package:huideng_counter/data/repositories/forum_repository.dart';
import 'package:huideng_counter/presentation/forum_page.dart';
import 'package:huideng_counter/presentation/forum_compose_page.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/models.dart';

class MemoryCache extends HomeMessageCache {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    value = next;
  }
}

class Remote extends ForumRemote {
  Remote()
    : super(
        SupabaseClient(
          'https://example.com',
          'public-test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  bool fail = false;
  @override
  Future<List<Map<String, dynamic>>> sections() async => [
    for (final id in ['study', 'practice', 'resources', 'feedback'])
      {'id': id, 'count': 3, 'latest_title': '板块最新帖子'},
  ];
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async => {
    'post': {'id': '0', 'title': '佛法交流 0', 'body': '测试正文', 'author_name': '游客'},
    'replies': <Map<String, dynamic>>[],
    'liked': false,
    'bookmarked': false,
  };
  @override
  Future<List<Map<String, dynamic>>> feed({
    required String search,
    required String category,
    required String sort,
    required int offset,
  }) async {
    if (fail) throw StateError('offline');
    return List.generate(
      21,
      (i) => {
        'id': '$i',
        'title': '佛法交流 $i',
        'body': '测试正文',
        'author_name': '游客',
        'tags': <String>[],
      },
    );
  }
}

class UnusedCounter implements CounterRepository {
  @override
  Future<void> saveSetting(String key, String value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PublishingRepository extends ForumRepository {
  PublishingRepository() : super(null, MemoryCache());
  final requests = <Map<String, dynamic>>[];
  @override
  bool get signedIn => true;
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async {
    requests.add(Map.from(data));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (requests.length == 1) throw StateError('offline');
    return {'id': data['id']};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('failed publication retains text and retries the same UUID', (
    tester,
  ) async {
    final app = AppController(UnusedCounter());
    app.preferences['language'] = 'zh';
    final repo = PublishingRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ForumComposePage(
                  app: app,
                  openDraft: (_) async => MemoryDraft(),
                  repository: repo,
                  categories: forumCategories,
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final inputs = find.byType(TextFormField);
    await tester.enterText(inputs.at(0), '发布测试');
    await tester.enterText(inputs.at(1), '离线时仍保留的正文');
    await tester.tap(find.byKey(const ValueKey('forum-publish')));
    await tester.tap(
      find.byKey(const ValueKey('forum-publish')),
    ); // Same-frame double tap must be ignored.
    await tester.pumpAndSettle();
    expect(find.text('确认发布'), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('离线时仍保留的正文'), findsOneWidget);
    expect(repo.requests.length, 1);
    await tester.tap(find.byKey(const ValueKey('forum-publish')));
    await tester.tap(
      find.byKey(const ValueKey('forum-publish')),
    ); // Same-frame double tap must be ignored.
    await tester.pumpAndSettle();
    expect(find.text('确认发布'), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(repo.requests.length, 2);
    expect(repo.requests[0]['id'], repo.requests[1]['id']);
    expect(find.text('Open'), findsOneWidget);
    app.dispose();
  });
  testWidgets('title is optional and advanced choices stay collapsed', (
    tester,
  ) async {
    final app = AppController(UnusedCounter());
    app.preferences['language'] = 'zh';
    final repo = PublishingRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: ForumComposePage(
          app: app,
          openDraft: (_) async => MemoryDraft(),
          repository: repo,
          categories: forumCategories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('标题（选填）'), findsOneWidget);
    expect(find.text('发布类型'), findsNothing);
    await tester.enterText(find.byType(TextFormField).at(1), '只有正文也可以发布\n完整内容');
    await tester.ensureVisible(find.text('更多设置'));
    await tester.tap(find.text('更多设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile));
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forum-publish')));
    await tester.tap(
      find.byKey(const ValueKey('forum-publish')),
    ); // Same-frame double tap must be ignored.
    await tester.pumpAndSettle();
    expect(find.text('确认发布'), findsNothing);
    await tester.pumpAndSettle();
    expect(repo.requests.single['title'], '只有正文也可以发布');
    expect(repo.requests.single['body'], '完整内容');
    expect(repo.requests.single['attachments'], isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });
  test('missing service is distinct from permission and other errors', () {
    expect(
      forumServiceMissing(
        const PostgrestException(message: 'missing', code: 'PGRST202'),
      ),
      true,
    );
    expect(
      forumServiceMissing(
        const PostgrestException(message: 'missing', code: 'PGRST205'),
      ),
      true,
    );
    expect(
      forumServiceMissing(
        const PostgrestException(message: 'denied', code: '42501'),
      ),
      false,
    );
    expect(forumServiceMissing(StateError('offline')), false);
  });
  test(
    'pagination and offline cache never substitute for searches or other sorting',
    () async {
      final remote = Remote();
      final repo = ForumRepository(remote, MemoryCache());
      final first = await repo.feed();
      expect(first.items.length, 20);
      expect(first.hasMore, true);
      remote.fail = true;
      expect((await repo.feed()).cached, true);
      await expectLater(repo.feed(search: '找不到'), throwsStateError);
      await expectLater(repo.feed(sort: 'recommended'), throwsStateError);
      await expectLater(repo.feed(offset: 20), throwsStateError);
    },
  );
  testWidgets(
    'small screen shows text cards, opens detail, preserves website fallback',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AppController(UnusedCounter());
      app.preferences['language'] = 'zh';
      await tester.pumpWidget(
        MaterialApp(
          home: ForumPage(
            app: app,
            repository: ForumRepository(Remote(), MemoryCache()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('推荐'), findsNothing);
      expect(find.text('红书'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      final firstCard = tester.getRect(find.byType(ForumPostCard).at(0));
      final secondColumn = tester.getRect(find.byType(ForumPostCard).at(1));
      expect(secondColumn.left, greaterThan(firstCard.right));
      expect(secondColumn.top, firstCard.top);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.byTooltip('版面设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单列'));
      await tester.pumpAndSettle();
      expect(app.preferences['forum_layout_mode'], 'list');
      expect(
        tester.getSize(find.byType(ForumPostCard).first).width,
        greaterThan(320),
      );
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.byTooltip('版面设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双列'));
      await tester.pumpAndSettle();
      expect(app.preferences['forum_layout_mode'], 'grid');
      expect(tester.getRect(find.byType(NavigationBar)).top, greaterThan(500));
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '佛法');
      await tester.tap(find.widgetWithText(TextButton, '搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('最新'), findsOneWidget);
      expect(find.text('热门'), findsOneWidget);
      expect(find.text('板块'), findsOneWidget);
      expect(find.text('我的帖子'), findsNothing);
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();
      expect(find.text('请先在“计数 → 设置 → 账号与同步”登录账号'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('个人菜单'));
      await tester.pumpAndSettle();
      expect(find.text('原论坛'), findsOneWidget);
      expect(find.text('我的回复'), findsOneWidget);
      await tester.tapAt(const Offset(10, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('板块'));
      await tester.pumpAndSettle();
      expect(find.text('学修'), findsOneWidget);
      expect(find.text('综合'), findsOneWidget);
      expect(find.text('活动'), findsOneWidget);
      expect(find.text('建议反馈'), findsNothing);
      expect(
        tester.getTopLeft(find.text('综合')).dy,
        lessThan(tester.getTopLeft(find.text('活动')).dy),
      );
      expect(
        tester.getTopLeft(find.text('活动')).dy,
        lessThan(tester.getTopLeft(find.text('学修')).dy),
      );
      expect(find.text('佛法问答'), findsNothing);
      expect(find.text('帖子：3'), findsWidgets);
      await tester.tap(find.text('学修'));
      await tester.pumpAndSettle();
      expect(find.text('学修'), findsWidgets);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最新'));
      await tester.pumpAndSettle();
      expect(find.text('佛法交流 0'), findsOneWidget);
      await tester.tap(find.text('佛法交流 0'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '游客'), findsOneWidget);
      await tester.tap(find.byTooltip('分享').first);
      await tester.pumpAndSettle();
      expect(find.text('分享给好友'), findsOneWidget);
      expect(find.text('分享到群聊'), findsOneWidget);
      await tester.tap(find.text('分享给好友'));
      await tester.pumpAndSettle();
      expect(find.text('聊天身份尚未就绪'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      app.dispose();
    },
  );
}
