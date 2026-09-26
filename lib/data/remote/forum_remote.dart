import '../../services/cloud_storage_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_remote.dart';
import 'package:flutter/foundation.dart';

bool forumServiceMissing(Object error) =>
    error is PostgrestException &&
    const ['PGRST202', 'PGRST205', '42P01', '42883'].contains(error.code);

class ForumRemote {
  final SupabaseClient client;
  ForumRemote(this.client);
  Future<String> sharedNickname() async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw const AuthException('login_required');
    }
    final nickname = await ChatRemote(client, user.id).ownNickname();
    if (nickname == null || nickname.trim().isEmpty) {
      throw StateError('shared_nickname_unavailable');
    }
    return nickname;
  }

  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async {
    var payload = data;
    if (action == 'create' || action == 'reply') {
      final userId = client.auth.currentUser?.id;
      final name = await sharedNickname();
      if (client.auth.currentUser?.id != userId) {
        throw const AuthException('login_required');
      }
      payload = {...data, 'nickname': name};
    }
    final value = await client
        .rpc('forum_action_v3', params: {'p_action': action, 'p_data': payload})
        // A valid full-length article can be several megabytes of UTF-8.
        // Keep ordinary reads responsive, while giving writes time to finish.
        .timeout(Duration(seconds: action == 'create' ? 120 : 20));
    final result = Map<String, dynamic>.from(value as Map);
    if (action == 'detail' &&
        result['post'] is Map &&
        result['post']['access_level'] == 'link_only' &&
        result['post']['owned'] != true) {
      final slug = payload['slug'];
      if (slug is String) {
        final page = await client.functions.invoke(
          'shared-page',
          body: {'slug': slug},
        );
        if (page.status == 200 && page.data is Map) {
          result['post'] = page.data['post'];
          return result;
        }
      }
    }

    if (result['post'] is Map) {
      result['post'] = await media(
        Map<String, dynamic>.from(result['post'] as Map),
      );
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> sections() async {
    final result = await client
        .rpc('forum_sections_v1')
        .timeout(const Duration(seconds: 15));
    return (result as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<Map<String, dynamic>> media(Map<String, dynamic> row) async {
    final images = List<String>.from(row['image_urls'] as List? ?? []);
    final attachments = <Map<String, dynamic>>[];
    for (final raw in row['attachments'] as List? ?? []) {
      final file = Map<String, dynamic>.from(raw as Map);
      try {
        file['url'] = await SupabaseStorageProvider(
          client,
        ).signedUrl('forum-files', file['path'] as String, 120);
        if (file['kind'] == 'image') images.add(file['url'] as String);
      } catch (e) {
        debugPrint('Forum attachment signing failed: ${e.runtimeType}');
      }
      attachments.add(file);
    }
    return {...row, 'image_urls': images, 'attachments': attachments};
  }

  Future<List<Map<String, dynamic>>> feed({
    required String search,
    required String category,
    required String sort,
    required int offset,
  }) async {
    if (category.startsWith('jieyuan:')) {
      final data = await client.rpc(
        'jieyuan_feed',
        params: {'p_type': category.split(':').last, 'p_offset': offset},
      );
      return Future.wait(
        (data['items'] as List).map((r) => media(Map<String, dynamic>.from(r))),
      );
    }
    final result = await client
        .rpc(
          'forum_feed_v2',
          params: {
            'p_search': search,
            'p_category': category,
            'p_sort': sort,
            'p_offset': offset,
          },
        )
        .timeout(const Duration(seconds: 15));
    return Future.wait(
      (result['items'] as List).map(
        (r) => media(Map<String, dynamic>.from(r as Map)),
      ),
    );
  }
}
