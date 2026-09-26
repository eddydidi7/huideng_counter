import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/remote/group_admin.dart';
import '../data/repositories/chat_repository.dart';
import 'group_admin_page.dart' show GroupMembersPage;
import 'chat_avatar.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatInfoPage extends StatefulWidget {
  const ChatInfoPage({
    super.key,
    required this.app,
    required this.repository,
    required this.room,
    required this.members,
    required this.title,
    required this.pinned,
    required this.muted,
    required this.onPreference,
    required this.restoreAvailable,
  });
  final AppController app;
  final ChatRepository repository;
  final Map<String, dynamic> room;
  final List<Map<String, dynamic>> members;
  final String title;
  final bool pinned, muted, restoreAvailable;
  final Future<void> Function(String) onPreference;
  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  bool busy = false;
  late bool pinned = widget.pinned, muted = widget.muted;
  late List<Map<String, dynamic>> members = widget.members;
  late String title = widget.title;
  bool canRename = false, refreshing = false;
  RealtimeChannel? channel;
  Timer? refreshTimer;
  @override
  void initState() {
    super.initState();
    refreshInfo();
    loadLocal();
    channel = widget.repository.remote.client
        .channel('chat-info:${widget.room['id']}:${identityHashCode(this)}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_messages',
          callback: (_) => refreshInfo(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_members',
          callback: (_) => refreshInfo(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_rooms',
          callback: (_) => refreshInfo(),
        )
        .subscribe();
    refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => refreshInfo(),
    );
  }

  // Groups: counts and the first 20 members come from the paged admin API,
  // so a 10,000-member group never downloads its whole roster here.
  late final GroupAdmin? admin = widget.room['kind'] == 'group'
      ? GroupAdmin(widget.repository.remote.client, widget.room['id'] as String)
      : null;
  int? memberCount;
  bool adminReady = false, savedToContacts = false;
  List<String> specialFollow = [];
  Map<String, String> specialNames = {};

  Future<void> loadLocal() async {
    final view = (await widget.repository.store.roomViews())[widget.room['id']];
    if (!mounted) return;
    setState(() {
      savedToContacts = view?['savedToContacts'] == true;
      specialFollow = [for (final id in view?['specialFollow'] as List? ?? []) '$id'];
      specialNames = {
        for (final e in (view?['specialFollowNames'] as Map? ?? {}).entries) '${e.key}': '${e.value}',
      };
    });
  }

  Future<void> saveLocal() => widget.repository.store.patchRoom(widget.room['id'] as String, {
    'savedToContacts': savedToContacts,
    'specialFollow': specialFollow,
    'specialFollowNames': specialNames,
  });

  Future<void> editSpecialFollow() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                dense: true,
                title: Text('特别关注'),
                subtitle: Text('即使本群开启免打扰，这些成员的消息仍会通知你（仅本机）'),
              ),
              for (final id in specialFollow)
                ListTile(
                  dense: true,
                  title: Text(specialNames[id] ?? id),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      specialFollow.remove(id);
                      specialNames.remove(id);
                      await saveLocal();
                      update(() {});
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_add_alt),
                title: const Text('添加成员'),
                onTap: admin == null || !adminReady
                    ? null
                    : () async {
                        final picked = await Navigator.push<Map<String, dynamic>>(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => GroupMembersPage(
                              app: widget.app,
                              admin: admin!,
                              myRole: 'member',
                              pickTitle: '选择特别关注的成员',
                            ),
                          ),
                        );
                        final id = picked?['user_id'] as String?;
                        if (id == null || specialFollow.contains(id)) return;
                        specialFollow.add(id);
                        specialNames[id] = '${picked!['group_nickname'] ?? picked['nickname'] ?? ''}';
                        await saveLocal();
                        update(() {});
                        if (mounted) setState(() {});
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> refreshInfo() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final remote = widget.repository.remote;
      List<Map<String, dynamic>>? paged;
      if (admin != null) {
        try {
          final overview = await admin!.overview();
          final page = await admin!.members(limit: 20);
          paged = [...GroupAdmin.rows(page['managers']), ...GroupAdmin.rows(page['items'])];
          memberCount = (overview['member_count'] as num?)?.toInt();
          adminReady = true;
        } catch (_) {
          paged = null; // Older server: fall back to the full roster below.
        }
      }
      final roster = paged ??
          ChatRepository.rows(
            await remote.call('members', {'room_id': widget.room['id']}),
          );
      final info = await remote.client.rpc(
        'group_manage_v2',
        params: {
          'p_action': 'info',
          'p_data': {'room_id': widget.room['id']},
        },
      );
      if (mounted) {
        setState(() {
          members = roster;
          if (widget.room['kind'] == 'group') title = info['title'] as String;
          canRename = info['can_rename'] == true;
        });
      }
    } catch (e) {
      debugPrint('Chat info refresh: $e');
    } finally {
      refreshing = false;
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    if (channel != null) {
      widget.repository.remote.client.removeChannel(channel!);
    }
    super.dispose();
  }

  String tr(String a, String b) => widget.app.text(a, b);
  void action(String value) => Navigator.pop(context, value);
  Widget tile(String zh, String en, String key) => ListTile(
    title: Text(tr(zh, en)),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => action(key),
  );
  @override
  Widget build(BuildContext context) {
    final group = widget.room['kind'] == 'group',
        owner = widget.room['owner_id'] == widget.repository.remote.userId;
    return Scaffold(
      appBar: AppBar(title: Text(tr('聊天信息', 'Chat info'))),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                for (final m in members.take(20))
                  SizedBox(
                    width: 64,
                    child: Column(
                      children: [
                        ChatAvatar(
                          remote: widget.repository.remote,
                          userId: m['user_id'],
                          radius: 27,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          m['nickname'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: OutlinedButton(
                    onPressed: () => action('invite'),
                    child: const Icon(Icons.add),
                  ),
                ),
              ],
            ),
          ),
          tile(
            '查看成员 (${memberCount ?? members.length})',
            'Members (${memberCount ?? members.length})',
            'members',
          ),
          if (group && adminReady)
            ListTile(
              key: const ValueKey('chat-info-group-admin'),
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(tr('群管理与设置', 'Group management')),
              subtitle: Text(
                tr('成员、禁言、公告、群文件、搜索、群昵称', 'Members, mutes, notices, files, search'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => action('group_admin'),
            ),
          if (group) tile('群文件、公告与共修', 'Group learning', 'group_learning'),
          if (group) tile('群二维码', 'Group QR code', 'qr'),
          if (group)
            ListTile(
              title: Text(tr('群聊名称', 'Group name')),
              subtitle: Text(title),
              trailing: canRename || owner
                  ? const Icon(Icons.chevron_right)
                  : null,
              onTap: canRename || owner ? () => action('rename') : null,
            ),
          const Divider(),
          tile('查找聊天记录', 'Search chat history', 'search'),
          SwitchListTile(
            title: Text(tr('消息免打扰', 'Mute notifications')),
            value: muted,
            onChanged: busy
                ? null
                : (_) async {
                    setState(() => busy = true);
                    // Fetch authoritative state; failed writes never fake a successful toggle.
                    try {
                      await widget.onPreference('mute');
                      final rooms = await widget.repository.rooms();
                      final r = rooms
                          .where((r) => r['id'] == widget.room['id'])
                          .firstOrNull;
                      if (mounted && r != null) {
                        setState(() => muted = r['muted'] == true);
                      }
                    } catch (_) {
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('更新失败，请重试', 'Could not update; retry'),
                            ),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
          ),
          SwitchListTile(
            title: Text(tr('置顶聊天', 'Pin chat')),
            value: pinned,
            onChanged: busy
                ? null
                : (_) async {
                    setState(() => busy = true);
                    try {
                      await widget.onPreference('pin');
                      final rooms = await widget.repository.rooms();
                      final r = rooms
                          .where((r) => r['id'] == widget.room['id'])
                          .firstOrNull;
                      if (mounted && r != null) {
                        setState(() => pinned = r['pinned'] == true);
                      }
                    } catch (_) {
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('更新失败，请重试', 'Could not update; retry'),
                            ),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
          ),
          if (group) ...[
            ListTile(
              title: Text(tr('特别关注', 'Special follow')),
              subtitle: Text(
                specialFollow.isEmpty
                    ? tr('未设置', 'None')
                    : specialFollow.map((id) => specialNames[id] ?? '').join('、'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: editSpecialFollow,
            ),
            SwitchListTile(
              title: Text(tr('保存到通讯录', 'Save to contacts')),
              subtitle: Text(tr('在通讯录“群聊”中置顶显示', 'Shown first under Groups')),
              value: savedToContacts,
              onChanged: (v) async {
                setState(() => savedToContacts = v);
                await saveLocal();
              },
            ),
          ],
          tile('提醒我查看聊天', 'Remind me', 'reminder'),
          const Divider(),
          tile('设置当前聊天背景', 'Chat background', 'background'),
          tile('清空本机聊天记录', 'Clear local history', 'clear_history'),
          if (widget.restoreAvailable)
            tile('恢复显示历史记录', 'Restore history', 'restore_history'),
          tile('已接收文件', 'Received files', 'received_files'),
          const Divider(),
          tile('投诉', 'Report', 'report'),
          if (!group) ...[
            tile('拉黑此用户', 'Block user', 'block_user'),
            tile('解除拉黑', 'Unblock user', 'unblock_user'),
          ],
          tile('删除本机会话', 'Remove conversation', 'delete_chat'),
          if (group && !owner) tile('退出群聊', 'Leave group', 'leave'),
          tile('重试 / 刷新', 'Refresh', 'refresh'),
        ],
      ),
    );
  }
}
