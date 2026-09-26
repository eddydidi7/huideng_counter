import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Follows, reads, bookmark counts and threaded comments
/// (community_social_v1, migration 202609250071). Guests use their
/// anonymous Auth identity, so no email registration is required.
class ForumSocial {
  ForumSocial(this.client);
  final SupabaseClient client;

  String? get userId => client.auth.currentUser?.id;

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (client.auth.currentUser == null) {
      throw const AuthException('login_required');
    }
    final value = await client
        .rpc('community_social_v1', params: {'p_action': action, 'p_data': data})
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(value as Map);
  }

  static List<Map<String, dynamic>> items(Map<String, dynamic> result) => [
    for (final raw in result['items'] as List? ?? [])
      Map<String, dynamic>.from(raw as Map),
  ];

  /// Cursor for keyset pagination from the last row of a page.
  static Map<String, dynamic> before(Map<String, dynamic> last, String field) =>
      {'before_at': last[field], 'before_id': last['id'] ?? last['user_id']};

  Future<Map<String, dynamic>> follow(String user, bool enabled) =>
      call('follow', {'user_id': user, 'enabled': enabled});
  Future<Map<String, dynamic>> followState(String user) =>
      call('follow_state', {'user_id': user});
  Future<List<Map<String, dynamic>>> people(
    String user, {
    required bool followers,
    Map<String, dynamic>? after,
  }) async => items(
    await call(followers ? 'followers' : 'following', {
      'user_id': user,
      'limit': 30,
      if (after != null) ...before(after, 'followed_at'),
    }),
  );

  Future<List<Map<String, dynamic>>> followingFeed({
    Map<String, dynamic>? after,
    int limit = 21,
  }) async => items(
    await call('following_feed', {
      'limit': limit,
      if (after != null) ...before(after, 'created_at'),
    }),
  );

  /// Counts one read per user per day; returns the post statistics.
  Future<Map<String, dynamic>> view(String post, {String? slug}) =>
      call('view', {'post_id': post, 'slug': ?slug});

  Future<Map<String, dynamic>> comments(
    String post, {
    String? slug,
    String? parent,
    Map<String, dynamic>? after,
    int limit = 20,
  }) => call('comments', {
    'post_id': post,
    'slug': ?slug,
    'parent_id': ?parent,
    'limit': limit,
    if (after != null && parent == null) ...before(after, 'created_at'),
    if (after != null && parent != null) ...{
      'after_at': after['created_at'],
      'after_id': after['id'],
    },
  });

  Future<Map<String, dynamic>> comment(
    String post,
    String body, {
    String? slug,
    String? replyTo,
    String? id,
  }) => call('comment', {
    'id': id ?? const Uuid().v4(),
    'post_id': post,
    'body': body,
    'slug': ?slug,
    'reply_to': ?replyTo,
  });

  Future<Map<String, dynamic>> likeComment(
    String reply,
    bool enabled, {
    String? slug,
  }) => call('comment_like', {
    'reply_id': reply,
    'enabled': enabled,
    'slug': ?slug,
  });

  Future<Map<String, dynamic>> deleteComment(String reply, {String? slug}) =>
      call('comment_delete', {'reply_id': reply, 'slug': ?slug});
}

bool forumSocialMissing(Object error) =>
    error is PostgrestException &&
    const ['PGRST202', '42883'].contains(error.code);

String forumCount(num? value) {
  final n = (value ?? 0).toInt();
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
