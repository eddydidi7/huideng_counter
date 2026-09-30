import 'dart:async';
import 'group_file_share.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/remote/group_admin.dart';
import '../services/attachment_service.dart';
import '../services/chat_image.dart';
import '../services/group_operation_error.dart';
import 'chat_avatar.dart';
import 'chat_page.dart' show chatText;
import 'public_profile_page.dart';

String _day(Object? value) {
  final at = DateTime.tryParse(value as String? ?? '')?.toLocal();
  if (at == null) return '';
  return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
}

String _time(Object? value) {
  final at = DateTime.tryParse(value as String? ?? '')?.toLocal();
  return at == null ? '' : at.toString().substring(0, 16);
}

String _size(Object? bytes) {
  final n = (bytes as num? ?? 0).toDouble();
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MB';
  return '${(n / 1024).toStringAsFixed(n < 10240 ? 1 : 0)} KB';
}

String? mutedText(Object? until) {
  final value = until?.toString();
  if (value == null) return null;
  if (value.contains('infinity')) return '永久禁言';
  final at = DateTime.tryParse(value)?.toLocal();
  if (at == null || at.isBefore(DateTime.now())) return null;
  return '禁言至 ${at.toString().substring(5, 16)}';
}

void _toast(BuildContext context, String text) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// Runs a management call and reports server rules in plain Chinese.
Future<bool> _run(BuildContext context, Future<void> Function() work, {String? done}) async {
  try {
    await work();
    if (done != null && context.mounted) _toast(context, done);
    return true;
  } catch (e) {
    if (context.mounted) _toast(context, groupOperationError(e));
    return false;
  }
}

/// Chooses a mute length in minutes (-1 permanent); null when cancelled.
Future<int?> pickMuteMinutes(BuildContext context) async {
  final choice = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(dense: true, title: Text('禁言时长')),
          for (final e in groupMuteOptions.entries)
            ListTile(
              dense: true,
              title: Text(e.key),
              onTap: () => Navigator.pop(ctx, e.value),
            ),
          ListTile(
            dense: true,
            title: const Text('自定义时长…'),
            onTap: () => Navigator.pop(ctx, -2),
          ),
        ],
      ),
    ),
  );
  if (choice != -2 || !context.mounted) return choice;
  final text = await chatText(context, '禁言多少小时（1～8760）', maxLength: 5);
  final hours = int.tryParse(text?.trim() ?? '');
  if (hours == null || hours < 1 || hours > 8760) return null;
  return hours * 60;
}

/// Shows the newest unread "show on entry" announcement once per member.
Future<void> showGroupAnnouncementPopup(BuildContext context, GroupAdmin admin) async {
  Map<String, dynamic>? item;
  try {
    item = await admin.popup();
  } catch (_) {
    return; // Not deployed yet or offline: never block entering the chat.
  }
  if (item == null || !context.mounted) return;
  final read = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text('群公告：${item!['title']}'),
      content: SingleChildScrollView(child: _AnnouncementBody(item: item)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('稍后再看'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('我已阅读'),
        ),
      ],
    ),
  );
  if (read == true) {
    try {
      await admin.ack(item['id'] as String);
    } catch (_) {}
  }
}

class _AnnouncementBody extends StatelessWidget {
  const _AnnouncementBody({required this.item, this.files});
  final Map<String, dynamic> item;
  final AttachmentService? files;
  @override
  Widget build(BuildContext context) {
    final payload = item['payload'] is Map ? item['payload'] as Map : const {};
    final links = [for (final l in payload['links'] as List? ?? []) '$l'];
    final attached = [
      for (final f in payload['files'] as List? ?? [])
        Map<String, dynamic>.from(f as Map),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(item['body'] as String? ?? ''),
        for (final link in links)
          TextButton(
            onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
            child: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        for (final f in attached)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              RegExp(r'\.(jpe?g|png|gif|webp|heic)$', caseSensitive: false).hasMatch('${f['file_name']}')
                  ? Icons.image_outlined
                  : Icons.description_outlined,
            ),
            title: Text('${f['file_name']}'),
            subtitle: Text(_size(f['file_size'])),
            onTap: files == null
                ? null
                : () async {
                    try {
                      await OpenFilex.open(await files!.download(f));
                    } catch (e) {
                      if (context.mounted) _toast(context, '文件无法打开：请确认仍在群文件中');
                    }
                  },
          ),
      ],
    );
  }
}

// ======================================================================
// Hub
// ======================================================================
class GroupAdminPage extends StatefulWidget {
  const GroupAdminPage({
    super.key,
    required this.app,
    required this.admin,
    required this.title,
  });
  final AppController app;
  final GroupAdmin admin;
  final String title;
  @override
  State<GroupAdminPage> createState() => _GroupAdminPageState();
}

class _GroupAdminPageState extends State<GroupAdminPage> {
  Map<String, dynamic>? data;
  String? error;
  GroupAdmin get admin => widget.admin;
  String get role => data?['my_role'] as String? ?? 'member';
  bool get manager => role == 'owner' || role == 'admin';
  bool get owner => role == 'owner';
  Map get settings => data?['settings'] as Map? ?? const {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await admin.overview();
      if (mounted) setState(() { data = value; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = groupOperationError(e));
    }
  }

  Future<void> open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    await load();
  }

  Widget tile(IconData icon, String title, VoidCallback onTap, {String? subtitle, Key? key}) => ListTile(
    key: key,
    dense: true,
    visualDensity: VisualDensity.compact,
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final block = data?['speak_block'] as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('群管理与设置')),
      body: data == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : TextButton(onPressed: load, child: Text(error!)),
            )
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                children: [
                  ListTile(
                    title: Text(data!['title'] as String? ?? widget.title),
                    subtitle: Text(
                      '${data!['member_count']} 位成员 · 管理员 ${data!['admin_count']}/10 · 我是${groupRoleLabel(role)}'
                      '${(settings['description'] as String? ?? '').isEmpty ? '' : '\n${settings['description']}'}',
                    ),
                  ),
                  if (block != null)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.all(8),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Text(groupAdminMessages[block] ?? block),
                    ),
                  tile(Icons.people_outline, '群成员（${data!['member_count']}）',
                      () => open(GroupMembersPage(app: widget.app, admin: admin, myRole: role)),
                      key: const ValueKey('group-admin-members')),
                  tile(Icons.campaign_outlined, '群公告',
                      () => open(GroupAnnouncementsPage(app: widget.app, admin: admin, manager: manager))),
                  tile(Icons.folder_outlined, '群文件',
                      () => open(GroupFilesPage(app: widget.app, admin: admin, manager: manager)),
                      subtitle: '文件名 · 大小 · 上传者 · 日期'),
                  tile(Icons.push_pin_outlined, '置顶消息',
                      () => open(GroupPinsPage(admin: admin, manager: manager))),
                  tile(Icons.manage_search, '搜索群内容',
                      () => open(GroupSearchPage(app: widget.app, admin: admin, myRole: role))),
                  tile(Icons.badge_outlined, '我的群昵称', () async {
                    final value = await chatText(context, '我的群昵称（留空恢复默认）',
                        initial: data?['my_nickname'] as String? ?? '', maxLength: 40);
                    if (value == null || !context.mounted) return;
                    if (await _run(context, () => admin.myNickname(value.trim()), done: '群昵称已保存')) await load();
                  }, subtitle: data?['my_nickname'] as String? ?? '未设置'),
                  if (manager) ...[
                    const Divider(),
                    SwitchListTile(
                      key: const ValueKey('group-admin-all-mute'),
                      dense: true,
                      secondary: const Icon(Icons.voice_over_off_outlined),
                      title: const Text('全员禁言'),
                      subtitle: const Text('开启后只有群主和管理员可以发言'),
                      value: settings['all_muted'] == true,
                      onChanged: (v) async {
                        if (await _run(context, () => admin.allMute(v))) await load();
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('group-admin-member-friend-add'),
                      dense: true,
                      secondary: const Icon(Icons.person_add_alt_1_outlined),
                      title: const Text('允许群成员互加好友'),
                      subtitle: const Text('关闭后普通成员不能通过群成员列表互加好友，已有好友关系不受影响'),
                      value: settings['allow_member_friend_add'] != false,
                      onChanged: (v) async {
                        if (await _run(context, () => admin.memberFriendAdd(v))) await load();
                      },
                    ),
                    tile(Icons.how_to_reg_outlined, '入群申请',
                        () => open(GroupRequestsPage(admin: admin)),
                        subtitle: '${data!['pending_requests']} 条待处理'),
                    tile(Icons.block_outlined, '黑名单（禁止再次加入）', () => open(GroupBansPage(admin: admin))),
                    tile(Icons.speed_outlined, '疑似刷屏成员', () => open(GroupSpamPage(admin: admin))),
                  ],
                  if (owner) ...[
                    const Divider(),
                    tile(Icons.tune, '群设置（入群方式、新成员、防刷屏等）',
                        () => open(GroupSettingsPage(app: widget.app, admin: admin, overview: data!)),
                        key: const ValueKey('group-admin-settings')),
                    tile(Icons.history, '群管理日志', () => open(GroupLogsPage(admin: admin))),
                    tile(Icons.swap_horiz, '转让群主', () async {
                      final target = await Navigator.push<Map<String, dynamic>>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => GroupMembersPage(
                            app: widget.app, admin: admin, myRole: role, pickTitle: '选择新群主'),
                        ),
                      );
                      if (target == null || !context.mounted) return;
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('转让群主？'),
                          content: Text('将群主转让给 ${target['nickname']}。转让后你将成为管理员（如管理员已满 10 位则为普通成员），无法撤销。'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认转让')),
                          ],
                        ),
                      );
                      if (ok == true && context.mounted &&
                          await _run(context, () => admin.transferOwner(target['user_id'] as String), done: '群主已转让')) {
                        await load();
                      }
                    }),
                  ],
                ],
              ),
            ),
    );
  }
}

// ======================================================================
// Members: paged, searchable, batch actions
// ======================================================================
class GroupMembersPage extends StatefulWidget {
  const GroupMembersPage({
    super.key,
    required this.app,
    required this.admin,
    required this.myRole,
    this.pickTitle,
  });
  final AppController app;
  final GroupAdmin admin;
  final String myRole;

  /// When set, tapping a member returns it (e.g. choosing a new owner).
  final String? pickTitle;
  @override
  State<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends State<GroupMembersPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> managers = [], items = [];
  int total = 0;
  bool loading = false, more = false, selecting = false;
  final selected = <String>{};
  String? error;
  Timer? debounce;
  GroupAdmin get admin => widget.admin;
  bool get manager => widget.myRole == 'owner' || widget.myRole == 'admin';

  @override
  void initState() {
    super.initState();
    load();
    search.addListener(() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 350), () => load());
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool append = false}) async {
    if (loading && append) return;
    setState(() { loading = true; error = null; });
    try {
      final page = await admin.members(
        query: search.text.trim(),
        after: append && items.isNotEmpty ? items.last : null,
      );
      final rows = GroupAdmin.rows(page['items']);
      if (!mounted) return;
      setState(() {
        if (!append) managers = GroupAdmin.rows(page['managers']);
        items = append ? [...items, ...rows] : rows;
        total = (page['total'] as num? ?? 0).toInt();
        more = rows.length == 50;
      });
    } catch (e) {
      if (mounted) setState(() => error = groupOperationError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Client-side hint only; the server enforces the same hierarchy.
  bool canManage(Map<String, dynamic> m) {
    if (m['user_id'] == admin.userId) return false;
    return switch (widget.myRole) {
      'owner' => m['role'] != 'owner',
      'admin' => m['role'] == 'member',
      _ => false,
    };
  }

  String name(Map<String, dynamic> m) =>
      (m['group_nickname'] as String?)?.isNotEmpty == true ? '${m['group_nickname']}' : '${m['nickname'] ?? '学友'}';

  Future<void> actions(Map<String, dynamic> m) async {
    final owner = widget.myRole == 'owner', manageable = canManage(m);
    final muted = mutedText(m['muted_until']) != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: Text(name(m)),
              subtitle: Text('${groupRoleLabel(m['role'] as String?)} · 入群 ${_day(m['joined_at'])}'
                  '${m['personal_number'] == null ? '' : ' · 个人号 ${m['personal_number']}'}'),
            ),
            ListTile(dense: true, leading: const Icon(Icons.person_outline), title: const Text('查看个人主页'),
                onTap: () => Navigator.pop(ctx, 'profile')),
            if (owner && m['role'] != 'owner')
              ListTile(dense: true, leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: Text(m['role'] == 'admin' ? '取消管理员' : '设为管理员'),
                  onTap: () => Navigator.pop(ctx, 'admin')),
            if (manageable) ...[
              ListTile(dense: true, leading: const Icon(Icons.volume_off_outlined), title: const Text('禁言…'),
                  onTap: () => Navigator.pop(ctx, 'mute')),
              if (muted)
                ListTile(dense: true, leading: const Icon(Icons.volume_up_outlined), title: const Text('解除禁言'),
                    onTap: () => Navigator.pop(ctx, 'unmute')),
              ListTile(dense: true, leading: const Icon(Icons.edit_note), title: const Text('设置群内备注'),
                  onTap: () => Navigator.pop(ctx, 'remark')),
              ListTile(dense: true, leading: const Icon(Icons.delete_sweep_outlined), title: const Text('删除其近 24 小时消息'),
                  onTap: () => Navigator.pop(ctx, 'purge')),
              ListTile(dense: true, leading: const Icon(Icons.logout), title: const Text('移出群聊（以后仍可再次加入）'),
                  onTap: () => Navigator.pop(ctx, 'remove')),
              ListTile(dense: true, leading: const Icon(Icons.block), title: const Text('移出并加入黑名单（禁止再次加入）'),
                  onTap: () => Navigator.pop(ctx, 'ban')),
            ],
            if (owner && m['role'] == 'member')
              SwitchListTile(
                dense: true,
                title: const Text('全员禁言时允许发言'),
                value: m['exempt_all_mute'] == true,
                onChanged: (v) => Navigator.pop(ctx, v ? 'exempt_on' : 'exempt_off'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final id = m['user_id'] as String;
    switch (choice) {
      case 'profile':
        await Navigator.push(context,
            MaterialPageRoute<void>(builder: (_) => PublicProfilePage(
                app: widget.app, userId: id, groupId: admin.roomId)));
        return;
      case 'admin':
        await _run(context, () => admin.setAdmin(id, m['role'] != 'admin'),
            done: m['role'] == 'admin' ? '已取消管理员' : '已设为管理员');
      case 'mute':
        final minutes = await pickMuteMinutes(context);
        if (minutes == null || !mounted) return;
        await _run(context, () => admin.mute([id], minutes), done: '已禁言');
      case 'unmute':
        await _run(context, () => admin.mute([id], 0), done: '已解除禁言');
      case 'remark':
        final value = await chatText(context, '群内备注（仅管理员可见）',
            initial: m['admin_remark'] as String? ?? '', maxLength: 80);
        if (value == null || !mounted) return;
        await _run(context, () => admin.remark(id, value.trim()), done: '备注已保存');
      case 'purge':
        if (!await _confirm('删除 ${name(m)} 近 24 小时的消息？', '所有成员设备上都会同步删除。')) return;
        if (!mounted) return;
        await _run(context, () => admin.purgeMember(id), done: '已删除');
      case 'remove':
      case 'ban':
        final ban = choice == 'ban';
        if (!await _confirm(ban ? '移出并拉黑 ${name(m)}？' : '移出 ${name(m)}？',
            ban ? '对方将无法通过邀请或二维码再次加入，除非管理员解除黑名单。' : '对方以后仍可被邀请再次加入。')) {
          return;
        }
        if (!mounted) return;
        await _run(context, () => admin.remove([id], ban: ban), done: ban ? '已移出并拉黑' : '已移出');
      case 'exempt_on':
      case 'exempt_off':
        await _run(context, () => admin.exempt(id, choice == 'exempt_on'));
    }
    await load();
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
          ],
        ),
      ) ??
      false;

  Future<void> batch(String action) async {
    final ids = selected.toList();
    if (ids.isEmpty) return;
    Map<String, dynamic>? result;
    if (action == 'mute') {
      final minutes = await pickMuteMinutes(context);
      if (minutes == null || !mounted) return;
      await _run(context, () async => result = await admin.mute(ids, minutes));
    } else {
      final ban = action == 'ban';
      if (!await _confirm(ban ? '批量移出并拉黑 ${ids.length} 人？' : '批量移出 ${ids.length} 人？',
          ban ? '他们将无法再次加入，除非管理员解除黑名单。' : '他们以后仍可被邀请再次加入。')) {
        return;
      }
      if (!mounted) return;
      await _run(context, () async => result = await admin.remove(ids, ban: ban));
    }
    if (result != null && mounted) {
      _toast(context, '已处理 ${result!['done']} 人${(result!['skipped'] as num? ?? 0) > 0 ? '，${result!['skipped']} 人无权限处理已跳过' : ''}');
    }
    setState(() { selected.clear(); selecting = false; });
    await load();
  }

  Widget memberTile(Map<String, dynamic> m) {
    final muted = mutedText(m['muted_until']);
    final pick = widget.pickTitle != null;
    final id = m['user_id'] as String;
    return ListTile(
      key: ValueKey('group-member-$id'),
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: selecting
          ? Checkbox(
              value: selected.contains(id),
              onChanged: canManage(m)
                  ? (v) => setState(() => v == true ? selected.add(id) : selected.remove(id))
                  : null,
            )
          : ChatAvatar(
              app: widget.app,
              groupId: admin.roomId,
              remote: null,
              publicClient: admin.client,
              userId: id,
              radius: 18,
            ),
      title: Row(
        children: [
          Flexible(child: Text(name(m), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (m['role'] != 'member') ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: m['role'] == 'owner' ? Colors.orange : Colors.blue,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(groupRoleLabel(m['role'] as String?),
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          '个人号：${m['personal_number'] ?? '未设置'}',
          '入群 ${_day(m['joined_at'])}',
          ?muted,
          if (m['exempt_all_mute'] == true) '全员禁言可发言',
          if ((m['admin_remark'] as String?)?.isNotEmpty == true) '备注：${m['admin_remark']}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: pick
          ? (m['role'] == 'owner' ? null : () => Navigator.pop(context, m))
          : selecting
          ? (canManage(m) ? () => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id)) : null)
          : () => actions(m),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.pickTitle ?? (selecting ? '已选择 ${selected.length} 人' : '群成员（$total）')),
      actions: [
        if (manager && widget.pickTitle == null)
          TextButton(
            onPressed: () => setState(() { selecting = !selecting; selected.clear(); }),
            child: Text(selecting ? '取消' : '批量'),
          ),
      ],
    ),
    bottomNavigationBar: selecting
        ? SafeArea(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(onPressed: selected.isEmpty ? null : () => batch('mute'), child: const Text('批量禁言')),
                TextButton(onPressed: selected.isEmpty ? null : () => batch('remove'), child: const Text('批量移出')),
                TextButton(onPressed: selected.isEmpty ? null : () => batch('ban'), child: const Text('移出并拉黑')),
              ],
            ),
          )
        : null,
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索昵称、群昵称或个人号',
            ),
          ),
        ),
        if (error != null) TextButton(onPressed: load, child: Text(error!)),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              children: [
                if (managers.isNotEmpty) ...[
                  const ListTile(dense: true, title: Text('群主和管理员')),
                  for (final m in managers) memberTile(m),
                  const Divider(height: 1),
                ],
                for (final m in items) memberTile(m),
                if (loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
                if (more && !loading) TextButton(onPressed: () => load(append: true), child: const Text('加载更多成员')),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

// ======================================================================
// Owner settings
// ======================================================================
class GroupSettingsPage extends StatefulWidget {
  const GroupSettingsPage({super.key, required this.app, required this.admin, required this.overview});
  final AppController app;
  final GroupAdmin admin;
  final Map<String, dynamic> overview;
  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  late Map<String, dynamic> s = Map<String, dynamic>.from(widget.overview['settings'] as Map);
  late String title = widget.overview['title'] as String? ?? '';
  String? avatarUrl;
  bool busy = false;
  GroupAdmin get admin => widget.admin;

  @override
  void initState() {
    super.initState();
    loadAvatar();
  }

  Future<void> loadAvatar() async {
    final path = s['avatar_path'] as String?;
    if (path == null) return;
    try {
      final url = await admin.client.storage.from('chat-avatars').createSignedUrl(path, 600);
      if (mounted) setState(() => avatarUrl = url);
    } catch (_) {}
  }

  Future<void> set(String key, Object value) async {
    final previous = s[key];
    setState(() { s[key] = value; busy = true; });
    final ok = await _run(context, () => admin.settings({key: value}));
    if (mounted) setState(() { busy = false; if (!ok) s[key] = previous; });
  }

  Future<void> rename() async {
    final value = await chatText(context, '群名称', initial: title);
    if (value == null || value.trim().isEmpty || !mounted) return;
    final ok = await _run(context, () async {
      await admin.client.rpc('group_manage_v2', params: {
        'p_action': 'rename',
        'p_data': {'room_id': admin.roomId, 'title': value.trim()},
      });
    }, done: '群名称已修改');
    if (ok && mounted) setState(() => title = value.trim());
  }

  Future<void> avatar() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    await _run(context, () async {
      final bytes = await compute(compressChatImage, await picked.readAsBytes());
      final path = '${admin.userId}/group-${admin.roomId}-${const Uuid().v4()}.jpg';
      await admin.client.storage.from('chat-avatars').uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );
      await admin.settings({'avatar_path': path});
      s['avatar_path'] = path;
      bumpChatAvatarVersion();
    }, done: '群头像已更新');
    await loadAvatar();
  }

  Widget toggle(String key, String title, {String? subtitle, bool invert = false}) => SwitchListTile(
    dense: true,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: invert ? s[key] != true : s[key] == true,
    onChanged: busy ? null : (v) => set(key, invert ? !v : v),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('群设置')),
    body: ListView(
      children: [
        ListTile(
          leading: CircleAvatar(
            radius: 24,
            backgroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl!),
            child: avatarUrl == null ? const Icon(Icons.groups) : null,
          ),
          title: const Text('群头像'),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : avatar,
        ),
        ListTile(dense: true, title: const Text('群名称'), subtitle: Text(title), onTap: rename),
        ListTile(
          dense: true,
          title: const Text('群简介'),
          subtitle: Text((s['description'] as String? ?? '').isEmpty ? '未填写' : s['description'] as String,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () async {
            final value = await chatText(context, '群简介', initial: s['description'] as String? ?? '', maxLength: 500);
            if (value != null && mounted) await set('description', value.trim());
          },
        ),
        const Divider(),
        const ListTile(dense: true, title: Text('入群方式')),
        RadioGroup<String>(
          groupValue: s['join_mode'] as String? ?? 'open',
          onChanged: (v) {
            if (!busy && v != null) set('join_mode', v);
          },
          child: const Column(
            children: [
              RadioListTile(dense: true, value: 'open', title: Text('直接加入'), subtitle: Text('扫码即可入群，无需审核')),
              RadioListTile(dense: true, value: 'approval', title: Text('管理员审核'), subtitle: Text('申请后由群主或管理员批准')),
              RadioListTile(dense: true, value: 'invite', title: Text('仅邀请加入'), subtitle: Text('只能由现有成员邀请')),
            ],
          ),
        ),
        toggle('managers_invite_only', '允许普通成员邀请别人', invert: true),
        toggle('allow_qr', '允许通过群二维码加入'),
        ListTile(
          dense: true,
          title: const Text('群二维码有效期'),
          trailing: DropdownButton<int>(
            value: [1, 7, 30, 90, 365].contains(s['qr_valid_days']) ? s['qr_valid_days'] as int : 7,
            items: [
              for (final d in [1, 7, 30, 90, 365]) DropdownMenuItem(value: d, child: Text('$d 天')),
            ],
            onChanged: busy ? null : (v) => set('qr_valid_days', v!),
          ),
        ),
        toggle('joins_paused', '暂停新成员加入', subtitle: '群主和管理员仍可邀请'),
        const Divider(),
        const ListTile(dense: true, title: Text('新成员')),
        ListTile(
          dense: true,
          title: const Text('新成员入群后禁言'),
          trailing: DropdownButton<int>(
            value: groupNewMemberMuteOptions.containsValue(s['new_member_mute_minutes'])
                ? s['new_member_mute_minutes'] as int
                : 0,
            items: [
              for (final e in groupNewMemberMuteOptions.entries) DropdownMenuItem(value: e.value, child: Text(e.key)),
            ],
            onChanged: busy ? null : (v) => set('new_member_mute_minutes', v!),
          ),
        ),
        toggle('require_announcement_read', '新成员须先阅读群公告', subtitle: '需发布一条“进入群聊时弹出”的公告；点“我已阅读”后才能发言'),
        const Divider(),
        const ListTile(dense: true, title: Text('发言与文件')),
        toggle('all_muted', '全员禁言', subtitle: '只有群主和管理员可以发言'),
        toggle('spam_guard', '消息防刷屏', subtitle: '限制连续快速发言、重复内容、大量图片和链接；只做临时限制，不会自动永久封禁'),
        toggle('allow_member_nickname', '允许成员修改群昵称'),
        toggle('allow_upload', '允许成员上传群文件'),
        toggle('history_files', '新成员可查看入群前的群文件'),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('群文件保存在云端（计入群存储配额）。大文件临时传给附近设备请用“面对面快传”，不会占用云端空间。'),
        ),
      ],
    ),
  );
}

// ======================================================================
// Announcements (text, links, images/files from group files; pin; popup)
// ======================================================================
/// Shared with [GroupFilesPage], which surfaces the latest announcement at
/// its own top banner instead of duplicating this dialog.
Future<void> viewGroupAnnouncement(
  BuildContext context,
  GroupAdmin admin,
  Map<String, dynamic> item,
  bool manager,
  AttachmentService files,
  Future<void> Function() reload,
) async {
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(item['title'] as String),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${item['author_name'] ?? ''} · ${_time(item['created_at'])}'
                '${manager ? ' · 已读 ${item['read_count']}' : ''}',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            _AnnouncementBody(item: item, files: files),
          ],
        ),
      ),
      actions: [
        if (manager) TextButton(onPressed: () => Navigator.pop(ctx, 'edit'), child: const Text('编辑')),
        if (manager) TextButton(onPressed: () => Navigator.pop(ctx, 'remove'), child: const Text('删除')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'read'),
          child: Text(item['is_read'] == true ? '关闭' : '我已阅读'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (action == 'read' && item['is_read'] != true) {
    await _run(context, () => admin.ack(item['id'] as String));
  } else if (action == 'edit') {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _AnnouncementEditor(admin: admin, item: item)),
    );
  } else if (action == 'remove') {
    await _run(context, () => admin.removeAnnouncement(item['id'] as String), done: '公告已删除');
  }
  await reload();
}

class GroupAnnouncementsPage extends StatefulWidget {
  const GroupAnnouncementsPage({super.key, required this.app, required this.admin, required this.manager});
  final AppController app;
  final GroupAdmin admin;
  final bool manager;
  @override
  State<GroupAnnouncementsPage> createState() => _GroupAnnouncementsPageState();
}

class _GroupAnnouncementsPageState extends State<GroupAnnouncementsPage> {
  List<Map<String, dynamic>> items = [];
  bool loading = false, more = false;
  late final files = AttachmentService(widget.admin.client);
  GroupAdmin get admin => widget.admin;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool append = false}) async {
    setState(() => loading = true);
    try {
      final rows = await admin.announcements(after: append && items.isNotEmpty ? items.last : null);
      if (mounted) setState(() { items = append ? [...items, ...rows] : rows; more = rows.length == 30; });
    } catch (e) {
      if (mounted) _toast(context, groupOperationError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> view(Map<String, dynamic> item) =>
      viewGroupAnnouncement(context, admin, item, widget.manager, files, load);

  Future<void> edit([Map<String, dynamic>? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _AnnouncementEditor(admin: admin, item: item)),
    );
    if (saved == true) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('群公告')),
    floatingActionButton: widget.manager
        ? FloatingActionButton.extended(
            heroTag: 'group-announce',
            onPressed: () => edit(),
            icon: const Icon(Icons.add),
            label: const Text('发布公告'),
          )
        : null,
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        children: [
          if (items.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('暂无群公告')),
          for (final item in items)
            ListTile(
              dense: true,
              leading: Icon(item['is_pinned'] == true ? Icons.push_pin : Icons.campaign_outlined),
              title: Text(item['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${_time(item['created_at'])}${item['popup'] == true ? ' · 进群弹出' : ''}'
                '${item['is_read'] == true ? ' · 已读' : ' · 未读'}',
              ),
              onTap: () => view(item),
            ),
          if (loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
          if (more && !loading) TextButton(onPressed: () => load(append: true), child: const Text('查看更早的公告')),
        ],
      ),
    ),
  );
}

class _AnnouncementEditor extends StatefulWidget {
  const _AnnouncementEditor({required this.admin, this.item});
  final GroupAdmin admin;
  final Map<String, dynamic>? item;
  @override
  State<_AnnouncementEditor> createState() => _AnnouncementEditorState();
}

class _AnnouncementEditorState extends State<_AnnouncementEditor> {
  late final Map payload = widget.item?['payload'] is Map ? widget.item!['payload'] as Map : const {};
  late final title = TextEditingController(text: widget.item?['title'] as String? ?? '');
  late final body = TextEditingController(text: widget.item?['body'] as String? ?? '');
  late final links = TextEditingController(text: [for (final l in payload['links'] as List? ?? []) '$l'].join('\n'));
  late final List<Map<String, dynamic>> attached = [
    for (final f in payload['files'] as List? ?? []) Map<String, dynamic>.from(f as Map),
  ];
  late bool pinned = widget.item?['is_pinned'] == true, popup = widget.item?['popup'] == true;
  bool busy = false;

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    links.dispose();
    super.dispose();
  }

  Future<void> attach() async {
    final chosen = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => GroupFilesPage(app: null, admin: widget.admin, manager: false, pick: true)),
    );
    if (chosen != null && mounted) {
      setState(() => attached.add({
            for (final k in ['id', 'file_id', 'file_name', 'file_size', 'object_key', 'bucket', 'checksum', 'storage_provider'])
              k: chosen[k],
          }));
    }
  }

  Future<void> save() async {
    final urls = links.text.split(RegExp(r'\s+')).where((l) => l.startsWith('http')).toList();
    if (title.text.trim().isEmpty) return;
    setState(() => busy = true);
    final ok = await _run(context, () => widget.admin.announce({
          if (widget.item != null) 'id': widget.item!['id'],
          'title': title.text.trim(),
          'body': body.text,
          'is_pinned': pinned,
          'popup': popup,
          'payload': {'links': urls, 'files': attached},
        }), done: '公告已发布');
    if (!mounted) return;
    setState(() => busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.item == null ? '发布群公告' : '编辑群公告'),
      actions: [TextButton(onPressed: busy ? null : save, child: const Text('发布'))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(controller: title, maxLength: 160, decoration: const InputDecoration(labelText: '标题')),
        TextField(controller: body, minLines: 4, maxLines: 12, decoration: const InputDecoration(labelText: '内容')),
        TextField(controller: links, minLines: 1, maxLines: 4,
            decoration: const InputDecoration(labelText: '链接（每行一个，http 开头）')),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('图片 / 文件'),
            const Spacer(),
            TextButton.icon(onPressed: attach, icon: const Icon(Icons.attach_file), label: const Text('从群文件选择')),
          ],
        ),
        for (final f in attached)
          ListTile(
            dense: true,
            title: Text('${f['file_name']}'),
            subtitle: Text(_size(f['file_size'])),
            trailing: IconButton(onPressed: () => setState(() => attached.remove(f)), icon: const Icon(Icons.close)),
          ),
        SwitchListTile(dense: true, title: const Text('置顶公告'), value: pinned, onChanged: (v) => setState(() => pinned = v)),
        SwitchListTile(
          dense: true,
          title: const Text('重要：进入群聊时弹出一次'),
          subtitle: const Text('成员点击“我已阅读”后不再弹出'),
          value: popup,
          onChanged: (v) => setState(() => popup = v),
        ),
      ],
    ),
  );
}

// ======================================================================
// Group files (paged; name | size | uploader | date; pin; search)
// ======================================================================
class GroupFilesPage extends StatefulWidget {
  const GroupFilesPage({super.key, required this.app, required this.admin, required this.manager, this.pick = false});
  final AppController? app;
  final GroupAdmin admin;
  final bool manager, pick;
  @override
  State<GroupFilesPage> createState() => _GroupFilesPageState();
}

class _GroupFilesPageState extends State<GroupFilesPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic>? announcement;
  bool loading = false, more = false;
  Timer? debounce;
  late final files = AttachmentService(widget.admin.client);

  @override
  void initState() {
    super.initState();
    load();
    loadAnnouncement();
    search.addListener(() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 350), () => load());
    });
  }

  // Pinned first, then most recent (same ordering group_admin_v1 returns);
  // the files page only ever needs the single current one to show up top.
  Future<void> loadAnnouncement() async {
    try {
      final rows = await widget.admin.announcements();
      if (mounted) setState(() => announcement = rows.isEmpty ? null : rows.first);
    } catch (_) {
      /* Non-fatal: the files list still works without the banner. */
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool append = false}) async {
    setState(() => loading = true);
    try {
      final rows = await widget.admin.files(
        query: search.text.trim(),
        after: append && items.isNotEmpty ? items.last : null,
      );
      if (mounted) setState(() { items = append ? [...items, ...rows] : rows; more = rows.length == 50; });
    } catch (e) {
      if (mounted) _toast(context, groupOperationError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> upload() async {
    // Group files are not limited to gallery media. FilePicker opens Android's
    // document provider so users can browse Downloads and other locations.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      if (mounted) _toast(context, '无法读取所选文件，请换一个文件重试');
      return;
    }
    if (!mounted) return;
    await _run(
      context,
      () => files.uploadGroup(widget.admin.roomId, path, picked.name),
      done: '已上传到群文件',
    );
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.pick ? '选择群文件' : '群文件')),
    floatingActionButton: widget.pick
        ? null
        : FloatingActionButton(heroTag: 'group-file-upload', onPressed: upload, child: const Icon(Icons.upload)),
    body: Column(
      children: [
        if (announcement != null)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: InkWell(
              onTap: () => viewGroupAnnouncement(
                context, widget.admin, announcement!, widget.manager, files, loadAnnouncement),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('📢', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('群公告 · ${announcement!['title']}',
                              style: Theme.of(context).textTheme.titleSmall,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text('${announcement!['body'] ?? ''}',
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    if (widget.app != null)
                      IconButton(
                        tooltip: '历史公告',
                        icon: const Icon(Icons.history, size: 20),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(
                            builder: (_) => GroupAnnouncementsPage(
                                app: widget.app!, admin: widget.admin, manager: widget.manager))),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: '搜索文件名'),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              children: [
                if (items.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('暂无群文件')),
                for (final f in items)
                  ListTile(
                    dense: true,
                    leading: Icon(f['is_pinned'] == true ? Icons.push_pin : Icons.description_outlined),
                    title: Text('${f['file_name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${_size(f['file_size'])} · ${f['uploader_name'] ?? ''} · ${_day(f['created_at'])}'),
                    trailing: !widget.pick
                        ? PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'public') {
                                await publishGroupFile(context, files, f);
                              } else if (v == 'pin') {
                                await _run(context, () => widget.admin.pinFile(f['id'] as String, f['is_pinned'] != true));
                              } else {
                                await _run(context, () async {
                                  await files.group('file_remove', {'group_id': widget.admin.roomId, 'id': f['id']});
                                }, done: '已删除群文件');
                              }
                              await load();
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'public', child: Text('转存到公共网盘')),
                              if (widget.manager) PopupMenuItem(value: 'pin', child: Text(f['is_pinned'] == true ? '取消置顶' : '置顶')),
                              if (widget.manager) const PopupMenuItem(value: 'remove', child: Text('删除')),
                            ],
                          )
                        : null,
                    onTap: widget.pick
                        ? () => Navigator.pop(context, f)
                        : () => _run(context, () async => OpenFilex.open(await files.download(f))),
                  ),
                if (loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
                if (more && !loading) TextButton(onPressed: () => load(append: true), child: const Text('加载更多')),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

// ======================================================================
// Search (server-side, paged; kinds, member filter, date range)
// ======================================================================
class GroupSearchPage extends StatefulWidget {
  const GroupSearchPage({super.key, required this.app, required this.admin, required this.myRole});
  final AppController app;
  final GroupAdmin admin;
  final String myRole;
  @override
  State<GroupSearchPage> createState() => _GroupSearchPageState();
}

class _GroupSearchPageState extends State<GroupSearchPage> {
  final query = TextEditingController();
  String kind = '';
  Map<String, dynamic>? sender;
  DateTimeRange? range;
  List<Map<String, dynamic>> results = [];
  bool loading = false, more = false, searched = false;

  static const kinds = {'': '全部', 'text': '文字', 'image': '图片', 'video': '视频', 'file': '文件', 'link': '链接'};

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> run({bool append = false}) async {
    setState(() => loading = true);
    try {
      final rows = await widget.admin.search(
        query: query.text.trim(),
        kind: kind,
        sender: sender?['user_id'] as String?,
        from: range?.start,
        to: range?.end.add(const Duration(days: 1)),
        after: append && results.isNotEmpty ? results.last : null,
      );
      if (mounted) {
        setState(() { results = append ? [...results, ...rows] : rows; more = rows.length == 30; searched = true; });
      }
    } catch (e) {
      if (mounted) _toast(context, groupOperationError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('搜索群内容')),
    body: ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        TextField(
          controller: query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => run(),
          decoration: InputDecoration(
            isDense: true,
            hintText: '聊天记录、文件名…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(onPressed: run, icon: const Icon(Icons.arrow_forward)),
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final e in kinds.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: kind == e.key,
                onSelected: (_) {
                  setState(() => kind = e.key);
                  run();
                },
              ),
          ],
        ),
        Wrap(
          spacing: 6,
          children: [
            InputChip(
              avatar: const Icon(Icons.person_search, size: 18),
              label: Text(sender == null ? '按成员筛选' : '成员：${sender!['group_nickname'] ?? sender!['nickname']}'),
              onPressed: () async {
                final picked = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GroupMembersPage(
                        app: widget.app, admin: widget.admin, myRole: 'member', pickTitle: '选择成员'),
                  ),
                );
                if (picked != null) {
                  setState(() => sender = picked);
                  run();
                }
              },
              onDeleted: sender == null ? null : () { setState(() => sender = null); run(); },
            ),
            InputChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(range == null ? '按日期' : '${_day(range!.start.toIso8601String())} ~ ${_day(range!.end.toIso8601String())}'),
              onPressed: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() => range = picked);
                  run();
                }
              },
              onDeleted: range == null ? null : () { setState(() => range = null); run(); },
            ),
          ],
        ),
        if (searched && results.isEmpty && !loading) const Padding(padding: EdgeInsets.all(24), child: Text('没有找到相关内容')),
        for (final m in results)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(switch (m['attachment_kind']) {
              'image' => Icons.image_outlined,
              'file' => Icons.description_outlined,
              _ => Icons.chat_bubble_outline,
            }),
            title: Text(
              (m['body'] as String? ?? '').isNotEmpty ? m['body'] as String : '${m['attachment_name'] ?? '[附件]'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${m['nickname'] ?? ''} · ${_time(m['created_at'])}'),
          ),
        if (loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
        if (more && !loading) TextButton(onPressed: () => run(append: true), child: const Text('加载更多')),
      ],
    ),
  );
}

// ======================================================================
// Small lists: pins, requests, blacklist, spam watch, audit log
// ======================================================================
class GroupPinsPage extends StatefulWidget {
  const GroupPinsPage({super.key, required this.admin, required this.manager});
  final GroupAdmin admin;
  final bool manager;
  @override
  State<GroupPinsPage> createState() => _GroupPinsPageState();
}

class _GroupPinsPageState extends State<GroupPinsPage> {
  List<Map<String, dynamic>>? rows;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.admin.pins();
      if (mounted) setState(() => rows = value);
    } catch (e) {
      if (mounted) setState(() => rows = []);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('置顶消息')),
    body: rows == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              if (rows!.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('暂无置顶消息')),
              for (final m in rows!)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text((m['body'] as String? ?? '').isNotEmpty ? m['body'] as String : '${m['attachment_name'] ?? '[附件]'}'),
                  subtitle: Text('${m['nickname']} · ${_time(m['created_at'])}'),
                  trailing: widget.manager
                      ? IconButton(
                          tooltip: '取消置顶',
                          onPressed: () async {
                            await _run(context, () => widget.admin.pin(m['id'] as String, false));
                            await load();
                          },
                          icon: const Icon(Icons.close),
                        )
                      : null,
                ),
            ],
          ),
  );
}

class GroupRequestsPage extends StatefulWidget {
  const GroupRequestsPage({super.key, required this.admin});
  final GroupAdmin admin;
  @override
  State<GroupRequestsPage> createState() => _GroupRequestsPageState();
}

class _GroupRequestsPageState extends State<GroupRequestsPage> {
  List<Map<String, dynamic>>? rows;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.admin.requests();
      if (mounted) setState(() => rows = value);
    } catch (e) {
      if (mounted) { _toast(context, groupOperationError(e)); setState(() => rows = []); }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('入群申请')),
    body: rows == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              if (rows!.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('没有待处理的申请')),
              for (final r in rows!)
                ListTile(
                  dense: true,
                  title: Text('${r['nickname'] ?? '学友'}${r['personal_number'] == null ? '' : '（${r['personal_number']}）'}'),
                  subtitle: Text([
                    if (r['inviter_name'] != null) '${r['inviter_name']} 邀请',
                    if ((r['message'] as String? ?? '').isNotEmpty) '留言：${r['message']}',
                    _time(r['created_at']),
                  ].join(' · ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '拒绝',
                        onPressed: () async {
                          await _run(context, () => widget.admin.decide(r['id'] as String, false));
                          await load();
                        },
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        tooltip: '同意',
                        onPressed: () async {
                          await _run(context, () => widget.admin.decide(r['id'] as String, true), done: '已同意入群');
                          await load();
                        },
                        icon: const Icon(Icons.check),
                      ),
                    ],
                  ),
                ),
            ],
          ),
  );
}

class GroupBansPage extends StatefulWidget {
  const GroupBansPage({super.key, required this.admin});
  final GroupAdmin admin;
  @override
  State<GroupBansPage> createState() => _GroupBansPageState();
}

class _GroupBansPageState extends State<GroupBansPage> {
  List<Map<String, dynamic>>? rows;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.admin.bans();
      if (mounted) setState(() => rows = value);
    } catch (e) {
      if (mounted) { _toast(context, groupOperationError(e)); setState(() => rows = []); }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('黑名单')),
    body: rows == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              if (rows!.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('黑名单为空')),
              for (final b in rows!)
                ListTile(
                  dense: true,
                  title: Text('${b['nickname'] ?? '学友'}${b['personal_number'] == null ? '' : '（${b['personal_number']}）'}'),
                  subtitle: Text('加入黑名单：${_time(b['created_at'])}'),
                  trailing: TextButton(
                    onPressed: () async {
                      await _run(context, () => widget.admin.unban(b['user_id'] as String), done: '已解除，可再次邀请');
                      await load();
                    },
                    child: const Text('解除'),
                  ),
                ),
            ],
          ),
  );
}

class GroupSpamPage extends StatefulWidget {
  const GroupSpamPage({super.key, required this.admin});
  final GroupAdmin admin;
  @override
  State<GroupSpamPage> createState() => _GroupSpamPageState();
}

class _GroupSpamPageState extends State<GroupSpamPage> {
  List<Map<String, dynamic>>? rows;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.admin.spamWatch();
      if (mounted) setState(() => rows = value);
    } catch (e) {
      if (mounted) { _toast(context, groupOperationError(e)); setState(() => rows = []); }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('疑似刷屏成员')),
    body: rows == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('近 30 分钟发言 20 条以上的普通成员。系统只会临时限制发送，是否禁言或移出由管理员决定。'),
              ),
              if (rows!.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('暂无异常')),
              for (final r in rows!)
                ListTile(
                  dense: true,
                  title: Text('${r['nickname']}'),
                  subtitle: Text('30 分钟内 ${r['recent']} 条 · 链接 ${r['links']} · 图片 ${r['images']}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      final id = r['user_id'] as String;
                      if (v == 'mute') {
                        await _run(context, () => widget.admin.mute([id], 60), done: '已禁言 1 小时');
                      } else {
                        await _run(context, () => widget.admin.purgeMember(id, hours: 1), done: '已删除近 1 小时消息');
                      }
                      await load();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'mute', child: Text('禁言 1 小时')),
                      PopupMenuItem(value: 'purge', child: Text('删除其近 1 小时消息')),
                    ],
                  ),
                ),
            ],
          ),
  );
}

class GroupLogsPage extends StatefulWidget {
  const GroupLogsPage({super.key, required this.admin});
  final GroupAdmin admin;
  @override
  State<GroupLogsPage> createState() => _GroupLogsPageState();
}

class _GroupLogsPageState extends State<GroupLogsPage> {
  List<Map<String, dynamic>> rows = [];
  bool loading = false, more = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool append = false}) async {
    setState(() => loading = true);
    try {
      final value = await widget.admin.logs(
        before: append && rows.isNotEmpty ? (rows.last['id'] as num).toInt() : null,
      );
      if (mounted) setState(() { rows = append ? [...rows, ...value] : value; more = value.length == 50; });
    } catch (e) {
      if (mounted) _toast(context, groupOperationError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('群管理日志')),
    body: ListView(
      children: [
        if (rows.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('暂无记录')),
        for (final l in rows)
          ListTile(dense: true, title: Text(groupLogText(l)), subtitle: Text(_time(l['created_at']))),
        if (loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
        if (more && !loading) TextButton(onPressed: () => load(append: true), child: const Text('加载更早记录')),
      ],
    ),
  );
}
