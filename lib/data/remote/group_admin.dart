import 'package:supabase_flutter/supabase_flutter.dart';

/// Group administration API (group_admin_v1, migration 202609250072).
/// Every permission rule is enforced on the server; the client only hides
/// actions the current role cannot use.
class GroupAdmin {
  GroupAdmin(this.client, this.roomId);
  final SupabaseClient client;
  final String roomId;

  String? get userId => client.auth.currentUser?.id;

  Future<dynamic> call(String action, [Map<String, dynamic> data = const {}]) =>
      client
          .rpc(
            'group_admin_v1',
            params: {
              'p_action': action,
              'p_data': {'room_id': roomId, ...data},
            },
          )
          .timeout(const Duration(seconds: 20));

  static List<Map<String, dynamic>> rows(Object? value) => [
    for (final raw in value as List? ?? []) Map<String, dynamic>.from(raw as Map),
  ];

  static Map<String, dynamic> cursor(Map<String, dynamic> last, String field) =>
      {'before_at': last[field], 'before_id': last['id'] ?? last['user_id']};

  Future<Map<String, dynamic>> overview() async =>
      Map<String, dynamic>.from(await call('overview') as Map);

  Future<Map<String, dynamic>> members({
    String query = '',
    Map<String, dynamic>? after,
    int limit = 50,
  }) async => Map<String, dynamic>.from(
    await call('members', {
      'limit': limit,
      if (query.isNotEmpty) 'query': query,
      if (after != null) ...cursor(after, 'joined_at'),
    }) as Map,
  );

  /// minutes: 0 lifts the mute, -1 is permanent.
  Future<Map<String, dynamic>> mute(List<String> users, int minutes) async =>
      Map<String, dynamic>.from(
        await call('mute', {'user_ids': users, 'minutes': minutes}) as Map,
      );

  Future<Map<String, dynamic>> remove(List<String> users, {bool ban = false}) async =>
      Map<String, dynamic>.from(
        await call('remove', {'user_ids': users, 'ban': ban}) as Map,
      );

  Future<void> setAdmin(String user, bool enabled) =>
      call('set_admin', {'user_id': user, 'enabled': enabled});
  Future<void> exempt(String user, bool enabled) =>
      call('exempt', {'user_id': user, 'enabled': enabled});
  Future<void> remark(String user, String remark) =>
      call('remark', {'user_id': user, 'remark': remark});
  Future<void> settings(Map<String, dynamic> values) =>
      call('settings', {'settings': values});
  Future<void> allMute(bool enabled) => call('all_mute', {'enabled': enabled});
  Future<void> memberFriendAdd(bool enabled) =>
      call('member_friend_add', {'enabled': enabled});
  Future<void> transferOwner(String user) =>
      call('transfer_owner', {'user_id': user});
  Future<void> myNickname(String nickname) =>
      call('my_nickname', {'nickname': nickname});

  Future<List<Map<String, dynamic>>> bans() async => rows(await call('bans'));
  Future<void> unban(String user) => call('unban', {'user_id': user});
  Future<List<Map<String, dynamic>>> requests() async =>
      rows(await call('requests'));
  Future<void> decide(String request, bool approve) =>
      call('decide', {'request_id': request, 'approve': approve});

  Future<Map<String, dynamic>> deleteMessages(List<String> ids) async =>
      Map<String, dynamic>.from(await call('delete_messages', {'ids': ids}) as Map);
  Future<Map<String, dynamic>> purgeMember(String user, {int hours = 24}) async =>
      Map<String, dynamic>.from(
        await call('purge_member', {'user_id': user, 'hours': hours}) as Map,
      );
  Future<void> pin(String message, bool enabled) =>
      call('pin', {'message_id': message, 'enabled': enabled});
  Future<List<Map<String, dynamic>>> pins() async => rows(await call('pins'));

  Future<List<Map<String, dynamic>>> search({
    String query = '',
    String kind = '',
    String? sender,
    DateTime? from,
    DateTime? to,
    Map<String, dynamic>? after,
  }) async => rows(
    await call('search', {
      'limit': 30,
      if (query.isNotEmpty) 'query': query,
      if (kind.isNotEmpty) 'kind': kind,
      'user_id': ?sender,
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
      if (after != null) ...cursor(after, 'created_at'),
    }),
  );

  Future<List<Map<String, dynamic>>> files({
    String query = '',
    Map<String, dynamic>? after,
  }) async => rows(
    await call('files', {
      'limit': 50,
      if (query.isNotEmpty) 'query': query,
      if (after != null) ...cursor(after, 'created_at'),
    }),
  );
  Future<void> pinFile(String file, bool enabled) =>
      call('file_pin', {'file_id': file, 'enabled': enabled});

  Future<List<Map<String, dynamic>>> announcements({
    Map<String, dynamic>? after,
  }) async => rows(
    await call('announcements', {
      'limit': 30,
      if (after != null) ...cursor(after, 'created_at'),
    }),
  );
  Future<Map<String, dynamic>?> popup() async {
    final value = await call('popup');
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> ack(String item) => call('ack', {'item_id': item});
  Future<void> announce(Map<String, dynamic> data) => call('announce', data);
  Future<void> removeAnnouncement(String item) =>
      call('announcement_remove', {'item_id': item});

  Future<List<Map<String, dynamic>>> spamWatch() async =>
      rows(await call('spam_watch'));
  Future<List<Map<String, dynamic>>> logs({int? before}) async => rows(
    await call('logs', {'limit': 50, 'before_log': ?before}),
  );
}

/// Mute presets shown to managers (minutes; -1 = permanent, 0 = lift).
const groupMuteOptions = <String, int>{
  '10分钟': 10,
  '1小时': 60,
  '12小时': 720,
  '1天': 1440,
  '3天': 4320,
  '7天': 10080,
  '永久禁言': -1,
};

const groupNewMemberMuteOptions = <String, int>{
  '不禁言': 0,
  '10分钟': 10,
  '1小时': 60,
  '24小时': 1440,
};

String groupRoleLabel(String? role) => switch (role) {
  'owner' => '群主',
  'admin' => '管理员',
  _ => '成员',
};

String groupLogText(Map<String, dynamic> log) {
  final actor = log['actor_name'] as String? ?? '系统';
  final target = log['target_name'] as String? ?? '';
  final detail = log['detail'] is Map ? log['detail'] as Map : const {};
  String until() {
    final value = detail['until']?.toString();
    if (value == null) return '';
    if (value.contains('infinity')) return '（永久）';
    final at = DateTime.tryParse(value)?.toLocal();
    return at == null ? '' : '至 ${at.toString().substring(0, 16)}';
  }

  return switch (log['action']) {
    'set_admin' => '$actor 设置 $target 为管理员',
    'unset_admin' => '$actor 取消了 $target 的管理员',
    'mute' => '$actor 禁言了 $target${until()}',
    'unmute' => '$actor 解除了 $target 的禁言',
    'exempt' =>
      detail['enabled'] == true
          ? '$actor 允许 $target 在全员禁言时发言'
          : '$actor 取消了 $target 的全员禁言豁免',
    'all_mute' => detail['enabled'] == true ? '$actor 开启了全员禁言' : '$actor 关闭了全员禁言',
    'remove' => '$actor 将 $target 移出群聊',
    'ban' => '$actor 将 $target 加入黑名单',
    'unban' => '$actor 将 $target 移出黑名单',
    'approve_join' => '$actor 批准 $target 入群',
    'reject_join' => '$actor 拒绝了 $target 的入群申请',
    'rename' => '$actor 将群名称改为“${detail['to'] ?? ''}”',
    'settings' => '$actor 修改了群设置',
    'announcement' => '$actor 发布/修改了群公告“${detail['title'] ?? ''}”',
    'announcement_remove' => '$actor 删除了群公告“${detail['title'] ?? ''}”',
    'delete_messages' => '$actor 删除了 ${detail['count'] ?? ''} 条消息',
    'purge_member' => '$actor 删除了 $target 近 ${detail['hours'] ?? ''} 小时的 ${detail['count'] ?? ''} 条消息',
    'pin_message' => '$actor 置顶了一条消息',
    'unpin_message' => '$actor 取消了消息置顶',
    'transfer_owner' => '群主转让给了 $target',
    _ => '$actor ${log['action']}',
  };
}
