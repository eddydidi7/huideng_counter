import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/data/repositories/forum_edits.dart';
import 'package:huideng_counter/presentation/forum_edit_page.dart';

const owner = '00000000-0000-4000-8000-000000000001';

String token() {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': owner, 'role': 'authenticated', 'exp': 4102444800})}.test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('attachments keep server order; legacy images exclude signed URLs', () {
    final post = <String, dynamic>{
      'image_urls': ['https://old/1.jpg', 'https://signed/b', 'https://signed/a'],
      'attachments': [
        {'id': 'b', 'sort_order': 1, 'kind': 'image', 'url': 'https://signed/b'},
        {'id': 'f', 'sort_order': 2, 'kind': 'file', 'path': 'o/p/f', 'name': 'x.pdf'},
        {'id': 'a', 'sort_order': 0, 'kind': 'image', 'url': 'https://signed/a'},
      ],
    };
    expect(forumAttachmentsOf(post).map((a) => a['id']), ['a', 'b', 'f']);
    expect(forumLegacyImagesOf(post), ['https://old/1.jpg']);
    final payload = forumEditPayload(
      [
        {'id': 'n', 'path': 'o/p/n', 'name': 'new.jpg', 'kind': 'image'},
        {'id': 'a', 'path': 'o/p/a', 'name': 'a.jpg', 'kind': 'image', 'url': 'u'},
      ],
      [
        {'id': 'f', 'path': 'o/p/f', 'name': 'x.pdf', 'kind': 'file'},
      ],
    );
    expect(payload.map((a) => a['id']), ['n', 'a', 'f']);
    expect(payload[1].containsKey('url'), false);
  });

  test('media edits use v2, clean removed files only after success, and '
      'discarding cleans uploads', () async {
    final store = await ChatStore.openAt(inMemoryDatabasePath, owner);
    final calls = <String>[];
    final bodies = <String>[];
    var removed = <String>[];
    final client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.contains('/auth/')) {
          return http.Response(
            jsonEncode({
              'access_token': token(),
              'refresh_token': 'test-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': owner,
                'aud': 'authenticated',
                'role': 'authenticated',
                'is_anonymous': false,
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-09-19T00:00:00Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        calls.add('${request.method} ${request.url.path}');
        bodies.add(request.body);
        final rpc = request.url.path.contains('/rpc/');
        return http.Response(
          rpc
              ? jsonEncode({
                  'id': 'post',
                  'content_revision': 4,
                  'deleted': false,
                  'removed_paths': removed,
                })
              : '[]',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'test',
    );
    ForumEdits edits() =>
        ForumEdits(client, openStore: (id) async => ChatStore(store.db, id));
    final post = <String, dynamic>{
      'id': 'post',
      'author_user_id': owner,
      'title': 't',
      'body': 'b',
      'content_revision': 3,
    };

    // Text-only edits keep using v1 (works before the migration is deployed).
    await edits().save(post, 'edit', title: 't', body: 'text only');
    await edits().sync();
    expect(calls.last, contains('/rpc/forum_author_write_v1'));

    // Delete old image, add a new one, change text: one v2 request.
    removed = ['$owner/post/old'];
    await edits().save(
      post,
      'edit',
      title: 't',
      body: 'changed',
      attachments: [
        {'id': 'new', 'path': '$owner/post/new', 'name': 'n.jpg', 'kind': 'image'},
      ],
      uploadedPaths: ['$owner/post/new'],
    );
    calls.clear();
    bodies.clear();
    await edits().sync();
    expect(calls.first, contains('/rpc/forum_author_write_v2'));
    final data = jsonDecode(bodies.first)['p_data'] as Map;
    expect((data['attachments'] as List).single['id'], 'new');
    expect(data.containsKey('uploaded_paths'), false);
    expect(data.containsKey('local_post'), false);
    // Storage cleanup happens after the post update, for removed files only.
    expect(calls.last, contains('/storage/v1/object/forum-files'));
    expect(bodies.last, contains('$owner/post/old'));
    expect(bodies.last, isNot(contains('$owner/post/new')));
    expect(await edits().pending(), isEmpty);

    // Discarding an unsynced media edit removes its uploads.
    await edits().save(
      post,
      'edit',
      title: 't',
      body: 'later',
      attachments: const [],
      uploadedPaths: ['$owner/post/draft'],
    );
    calls.clear();
    bodies.clear();
    await edits().discard('post');
    expect(await edits().pending(), isEmpty);
    expect(calls.single, contains('/storage/v1/object/forum-files'));
    expect(bodies.single, contains('$owner/post/draft'));

    await client.dispose();
    await store.db.close();
  });
}
