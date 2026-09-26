import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/remote/forum_remote.dart';

class ProfileRemote extends ForumRemote {
  String name = '共用昵称';
  bool unavailable = false;
  ProfileRemote(super.client);
  @override
  Future<String> sharedNickname() async {
    if (unavailable) throw StateError('shared_nickname_unavailable');
    return name;
  }
}

void main() {
  test(
    'post and reply always use current shared name, preserving request UUID',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.test',
        'test-public',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{"id":"fixed-id"}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final remote = ProfileRemote(client);
      await remote.action('create', {
        'id': 'fixed-id',
        'nickname': '旧昵称',
        'body': '正文',
      });
      remote.name = '修改后的聊天昵称';
      await remote.action('reply', {
        'id': 'reply-id',
        'nickname': '',
        'body': '回复',
      });
      expect(requests[0]['p_data']['nickname'], '共用昵称');
      expect(requests[0]['p_data']['id'], 'fixed-id');
      expect(requests[1]['p_data']['nickname'], '修改后的聊天昵称');
      expect(requests[1]['p_data']['body'], '回复');
      remote.unavailable = true;
      await expectLater(
        remote.action('create', {'id': 'new', 'body': '不应发布'}),
        throwsStateError,
      );
      expect(requests.length, 2);
      await client.dispose();
    },
  );
}
