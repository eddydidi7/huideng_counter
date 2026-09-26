import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/remote/forum_remote.dart';
import 'package:huideng_counter/data/remote/forum_social.dart';
import 'package:huideng_counter/data/repositories/forum_repository.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/forum_comments.dart';
import 'package:huideng_counter/presentation/forum_image_viewer.dart';

const me = '00000000-0000-4000-8000-000000000001';
const author = '00000000-0000-4000-8000-000000000002';

String token() {
  String part(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': me, 'role': 'authenticated', 'exp': 4102444800})}.test';
}

/// Supabase client whose RPCs are answered by [reply] and recorded in [calls].
Future<SupabaseClient> fakeClient(
  List<Map<String, dynamic>> calls,
  Object? Function(String action, Map data) reply,
) async {
  final client = SupabaseClient(
    'https://example.test',
    'test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.contains('/auth/')) {
        return http.Response(
          jsonEncode({
            'access_token': token(),
            'refresh_token': 'r',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'is_anonymous': true,
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-09-19T00:00:00Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final body = request.body.isEmpty ? {} : jsonDecode(request.body) as Map;
      final action = body['p_action'] as String? ?? request.url.path;
      calls.add({'path': request.url.path, 'action': action, 'data': body['p_data']});
      return http.Response(
        jsonEncode(reply(action, body['p_data'] as Map? ?? {})),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  await client.auth.signInWithPassword(email: 'g@example.test', password: 'x');
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('counts use thousands separators', () {
    expect(forumCount(0), '0');
    expect(forumCount(809), '809');
    expect(forumCount(2315), '2,315');
    expect(forumCount(1234567), '1,234,567');
    expect(forumCount(null), '0');
  });

  test('guest (anonymous auth) follows and reads through one RPC', () async {
    final calls = <Map<String, dynamic>>[];
    final client = await fakeClient(calls, (action, data) => switch (action) {
      'follow' => {'following': data['enabled'], 'followers': 1, 'following_count': 0},
      'view' => {'view_count': 5, 'like_count': 1, 'bookmark_count': 2, 'reply_count': 3},
      _ => {'items': []},
    });
    final social = ForumSocial(client);
    expect((await social.follow(author, true))['following'], true);
    expect(calls.last['path'], contains('/rpc/community_social_v1'));
    expect(calls.last['data'], {'user_id': author, 'enabled': true});
    expect((await social.view('post', slug: 's'))['view_count'], 5);
    expect(calls.last['data'], {'post_id': 'post', 'slug': 's'});
    await social.people(
      author,
      followers: true,
      after: {'user_id': 'u9', 'followed_at': '2026-09-25T00:00:00Z'},
    );
    expect(calls.last['action'], 'followers');
    expect(calls.last['data']['before_id'], 'u9');
    expect(calls.last['data']['before_at'], '2026-09-25T00:00:00Z');
    await client.dispose();
  });

  test('following channel pages by the last post, newest first', () async {
    final calls = <Map<String, dynamic>>[];
    final client = await fakeClient(calls, (action, data) => {
      'items': [
        for (var i = 0; i < 21; i++)
          {'id': 'p$i', 'created_at': '2026-09-2${i % 9}T00:00:00Z', 'attachments': []},
      ],
    });
    final repo = ForumRepository(ForumRemote(client), HomeMessageCache(cacheKey: 'test_feed'));
    final first = await repo.feed(sort: 'following');
    expect(first.items, hasLength(20));
    expect(first.hasMore, isTrue);
    final feedCall = calls.lastWhere((c) => c['action'] == 'following_feed');
    expect(feedCall['data']['before_at'], isNull);
    await repo.feed(sort: 'following', after: first.items.last);
    final next = calls.lastWhere((c) => c['action'] == 'following_feed');
    expect(next['data']['before_id'], 'p19');
    await client.dispose();
  });

  testWidgets('full-screen viewer swipes, counts and closes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openForumImages(context, ['a', 'b', 'c'], 1),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey('forum-image-viewer-pages')),
      const Offset(-400, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('threaded comments: reply label, own delete only, like', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final client = await tester.runAsync(
      () => fakeClient(calls, (action, data) => switch (action) {
        'comments' => {
          'reply_count': 3,
          'items': [
            {
              'id': 'c1', 'user_id': author, 'author_name': '作者', 'body': '第一条评论',
              'created_at': '2026-09-25T00:00:00Z', 'like_count': 2, 'liked': false,
              'can_delete': false, 'child_count': 2,
              'children': [
                {
                  'id': 'c2', 'user_id': me, 'author_name': '我', 'body': '我的回复',
                  'parent_id': 'c1', 'reply_to_name': '作者', 'created_at': '2026-09-25T00:01:00Z',
                  'like_count': 0, 'liked': false, 'can_delete': true,
                },
              ],
            },
          ],
        },
        'comment_like' => {'enabled': true, 'like_count': 3},
        _ => {},
      }),
    );
    final db = await tester.runAsync(() => LocalDatabase.openAt(inMemoryDatabasePath));
    final app = AppController(SqliteCounterRepository(db!));
    int? count;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForumComments(
              app: app,
              social: ForumSocial(client!),
              postId: 'post',
              onCount: (n) => count = n,
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('第一条评论'), findsOneWidget);
    expect(find.textContaining('回复 @作者'), findsOneWidget);
    expect(find.textContaining('展开更多回复（1）'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget); // only on my own reply
    expect(count, 3);
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    final like = calls.lastWhere((c) => c['action'] == 'comment_like');
    expect(like['data'], {'reply_id': 'c1', 'enabled': true});
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await client.dispose();
      await db.close();
    });
  });
}
