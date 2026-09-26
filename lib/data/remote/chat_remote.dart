import 'package:supabase_flutter/supabase_flutter.dart';

class ChatRemote {
  final SupabaseClient client;
  final String userId;
  ChatRemote(this.client, this.userId);
  Future<dynamic> personalNumbers(dynamic result) async {
    if (result is! List || result.isEmpty) return result;
    final ids = result
        .whereType<Map>()
        .map((p) => p['user_id'])
        .whereType<String>()
        .toSet()
        .toList();
    if (ids.isEmpty) return result;
    final numbers = <String, dynamic>{};
    for (var i = 0; i < ids.length; i += 100) {
      final rows = await client
          .from('chat_profiles')
          .select('user_id,personal_number')
          .inFilter('user_id', ids.skip(i).take(100).toList())
          .timeout(const Duration(seconds: 20));
      for (final row in rows) {
        numbers[row['user_id'] as String] = row['personal_number'];
      }
    }
    checkUser();
    return [
      for (final row in result)
        {
          ...Map<String, dynamic>.from(row),
          'personal_number': numbers[row['user_id']],
        },
    ];
  }

  Future<dynamic> directory(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    checkUser();
    if (client.auth.currentSession?.isExpired ?? true) {
      await client.auth.refreshSession();
    }
    checkUser();
    final result = await client
        .rpc('chat_directory_v2', params: {'p_action': action, 'p_data': data})
        .timeout(const Duration(seconds: 20));
    checkUser();
    return personalNumbers(result);
  }

  Future<dynamic> contacts(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    checkUser();
    final result = await client
        .rpc('chat_contacts_v1', params: {'p_action': action, 'p_data': data})
        .timeout(const Duration(seconds: 20));
    checkUser();
    // 'list' wraps friends in an object and the RPC omits personal_number;
    // fill it from chat_profiles, the same source every other page reads.
    if (result is Map && result['friends'] is List) {
      return {
        ...Map<String, dynamic>.from(result),
        'friends': await personalNumbers(result['friends']),
      };
    }
    return personalNumbers(result);
  }

  /// Reads the recipient's server-side contact policy before opening a
  /// verification-message editor. The server still enforces the same policy
  /// on the actual friend-request write.
  Future<bool> requiresFriendApproval(String targetUserId) async {
    final value = await directory('check', {'user_id': targetUserId});
    return value is Map && value['require_friend_approval'] == true;
  }

  Future<String?> ownNumber() async {
    checkUser();
    final row = await client
        .from('chat_profiles')
        .select('personal_number')
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
    checkUser();
    return row?['personal_number']?.toString();
  }

  Future<String?> ownNickname() async {
    checkUser();
    final row = await client
        .from('chat_profiles')
        .select('nickname')
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
    checkUser();
    return row?['nickname'] as String?;
  }

  void checkUser() {
    if (client.auth.currentUser?.id != userId) {
      throw const AuthException('CHAT_LOGIN_REQUIRED');
    }
  }

  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    checkUser();
    if (client.auth.currentSession?.isExpired ?? true) {
      await client.auth.refreshSession();
    }
    checkUser();
    if (action == 'direct') await directory('check', data);
    final result = await client
        .rpc('chat_api_v1', params: {'p_action': action, 'p_data': data})
        .timeout(const Duration(seconds: 20));
    checkUser();
    return result;
  }

  RealtimeChannel listen(void Function() refresh) => client
      .channel('chat:$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_friend_requests',
        callback: (_) => refresh(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_friends',
        callback: (_) => refresh(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_messages',
        callback: (_) => refresh(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_rooms',
        callback: (_) => refresh(),
      )
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_members',
        callback: (_) => refresh(),
      )
      .subscribe();
}
