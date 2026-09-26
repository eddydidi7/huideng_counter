import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/data/repositories/forum_edits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'durable author changes retry identical payload and isolate accounts',
    () async {
      const owner = '00000000-0000-4000-8000-000000000001';
      final store = await ChatStore.openAt(inMemoryDatabasePath, owner);
      var failure = 'network_error';
      final requests = <String>[];
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.contains('/auth/')) {
            return http.Response(
              jsonEncode({
                'access_token': '${base64Url.encode(utf8.encode('{"alg":"HS256"}')).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode({'sub': owner, 'role': 'authenticated', 'exp': 4102444800}))).replaceAll('=', '')}.test',
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
          requests.add(request.body);
          return http.Response(
            failure.isEmpty
                ? '{"ok":true}'
                : jsonEncode({'message': failure, 'code': 'P0001'}),
            failure.isEmpty ? 200 : 409,
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
        'title': 'before',
        'body': 'original',
        'content_revision': 3,
      };
      await edits().save(post, 'edit', title: 'after', body: 'changed');
      expect((await edits().pending()).single['body'], 'changed');
      expect(
        await ChatStore(
          store.db,
          'another-account',
        ).read('forum_author_pending'),
        isEmpty,
      );
      await expectLater(
        edits().save({...post, 'author_user_id': 'other'}, 'delete'),
        throwsStateError,
      );
      await expectLater(edits().save(post, 'delete'), throwsStateError);
      await edits().sync();
      expect(await edits().pending(), hasLength(1));
      failure = '';
      await edits().sync();
      expect(await edits().pending(), isEmpty);
      expect(requests[0], requests[1]);
      final payload = jsonDecode(requests[0])['p_data'] as Map;
      expect(payload['post_id'], 'post');
      expect(payload['content_revision'], 3);
      expect(payload.containsKey('local_post'), false);
      await edits().save(post, 'delete');
      failure = 'content_conflict';
      await edits().sync();
      final count = requests.length;
      await edits().sync();
      expect(requests.length, count);
      expect((await edits().pending()).single['error'], 'content_conflict');
      await edits().discard('post');
      expect(await edits().pending(), isEmpty);
      await client.dispose();
      await store.db.close();
    },
  );
}
