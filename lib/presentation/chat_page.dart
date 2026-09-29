import 'package:shared_preferences/shared_preferences.dart';
import '../services/resource_upload_policy.dart';
import '../services/group_operation_error.dart';
import '../services/assistant_session.dart';
import '../services/broadcast_inbox.dart';
import 'file_assistant_page.dart';
import 'public_profile_page.dart';
import 'chat_guest_gate.dart';
import 'chat_qr_page.dart';
import 'chat_top_bar.dart';
import 'chat_privacy_page.dart';
import 'chat_friend_setting_page.dart';
import 'cloud_drive_page.dart';
import 'my_page.dart' show StorageStatusPage;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../data/local/chat_store.dart';
import '../data/remote/chat_remote.dart';
import '../data/repositories/chat_repository.dart';
import 'chat_room_page.dart';
import '../data/remote/chat_live.dart';
import 'direct_transfer_page.dart';
import 'chat_contacts_page.dart';
import '../domain/chat_view.dart';
import 'chat_history_actions.dart';
import 'chat_avatar.dart';

String chatError(AppController app, Object e) {
  final limit = resourceLimitMessage(e);
  if (limit != null) return limit;
  final group = groupAdminMessage(e);
  if (group != null) return group;
  final value = e.toString();
  String tr(String a, String b) => app.text(a, b);
  if (value.contains('APK') || value.contains('单文件限制')) {
    return tr(
      '安装包发送失败，本地文件已保留。请检查云存储大小限制（Supabase 免费项目最多50MB）与网络，再点击重试。',
      'APK send failed. Local file retained. Check storage size limits and network, then retry.',
    );
  }
  if (value.contains('CHAT_STRANGERS_DISABLED')) {
    return tr(
      '对方已关闭陌生人消息，仍可发送好友申请。',
      'This person only accepts messages from friends. You can send a friend request.',
    );
  }
  if (value.contains('PGRST202') || value.contains('42P01')) {
    return tr('聊天服务尚未部署，请先执行聊天配置脚本。', 'Chat service is not deployed yet.');
  }
  if (value.contains('CHAT_BLOCKED')) {
    return tr(
      '你与对方存在拉黑关系，无法聊天或邀请。',
      'Messaging is blocked between these accounts.',
    );
  }
  if (value.contains('CHAT_RATE_LIMIT')) {
    return tr('操作过于频繁，请稍后重试。', 'Too many requests. Try later.');
  }
  if (value.contains('CHAT_OWNER_CANNOT_LEAVE')) {
    return tr('群主暂不能退出自己创建的群。', 'The group owner cannot leave this group.');
  }
  if (value.contains('CHAT_RECALL_EXPIRED')) {
    return tr(
      '服务器撤回功能尚未更新，请联系管理员。',
      'The server recall feature needs updating. Contact the administrator.',
    );
  }
  if (value.contains('CHAT_RECALL_DENIED')) {
    return tr('只能撤回本人发送的消息。', 'You can only recall your own messages.');
  }
  if (value.contains('CHAT_NOT_MEMBER')) {
    return tr('你已不在这个会话中。', 'You are no longer a member.');
  }
  if (value.contains('CHAT_LOGIN_REQUIRED') || e is AuthException) {
    return tr('请重新登录后聊天。', 'Please sign in again.');
  }
  if (e is PostgrestException) {
    return tr(
      '服务器未接受此操作，请检查账号权限或输入。',
      'The server rejected this operation. Check permissions or input.',
    );
  }
  return tr(
    '网络连接失败，已保存的消息和待发内容仍保留，可重试。',
    'Connection failed. Cached messages and pending sends are retained.',
  );
}

Future<String?> chatText(
  BuildContext context,
  String title, {
  String initial = '',
  int maxLength = 80,
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Icon(Icons.close),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Icon(Icons.check),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return value;
}

class ChatPage extends StatelessWidget {
  final AppController app;
  final ValueChanged<int>? onUnreadChanged;
  const ChatPage({super.key, required this.app, this.onUnreadChanged});
  @override
  Widget build(BuildContext context) {
    final client = app.cloud?.client;
    if (client == null) {
      return Scaffold(
        appBar: AppBar(title: Text(app.text('聊天', 'Chat'))),
        body: Center(
          child: Text(
            app.text(
              '请先在“计数 → 设置 → 账号与同步”登录账号',
              'Sign in from Counter → Settings → Account and sync',
            ),
          ),
        ),
      );
    }
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      builder: (context, _) {
        final user = client.auth.currentUser;
        if (user == null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => onUnreadChanged?.call(0),
          );
          return ChatGuestGate(connect: app.cloud!.connectGuestChat);
        }
        return ChatHome(
          key: ValueKey(user.id),
          app: app,
          client: client,
          userId: user.id,
          onUnreadChanged: onUnreadChanged,
        );
      },
    );
  }
}

class ChatHome extends StatefulWidget {
  final AppController app;
  final SupabaseClient client;
  final String userId;
  final ValueChanged<int>? onUnreadChanged;
  const ChatHome({
    super.key,
    required this.app,
    required this.client,
    required this.userId,
    this.onUnreadChanged,
  });
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  ChatRepository? repository;
  ChatLive? live;
  String? liveError;
  RealtimeChannel? channel;
  Timer? timer, debounce;
  List<Map<String, dynamic>> rooms = [], people = [];
  String? error;
  String search = '';
  String myNickname = '';
  String? myNumber;
  bool savingNickname = false;
  bool gridMode = false;
  int nicknameRevision = 0;
  bool busy = false, active = true;
  int failures = 0;
  AppController get app => widget.app;
  String tr(String a, String b) => app.text(a, b);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialize();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(
          () => gridMode = p.getBool('chat.grid.${widget.userId}') ?? false,
        );
      }
    });
  }

  Future<void> initialize() async {
    try {
      final store = await ChatStore.open(widget.userId);
      if (!mounted) return;
      repository = ChatRepository(
        store,
        ChatRemote(widget.client, widget.userId),
      );
      final presencePreference = await store.read('presence_preference');
      if (!mounted) return;
      live = ChatLive(
        repository!.remote,
        invisible: presencePreference.firstOrNull?['invisible'] == true,
      );
      live!.addListener(liveChanged);
      // Keeps this device visible to the account's other devices.
      unawaited(
        AssistantManager.instance.ensure(widget.client).catchError((Object _) {}),
      );
      rooms = await store.read('rooms');
      views = await store.roomViews();
      emitUnread();
      final cachedProfile = await store.read('own_profile');
      if (cachedProfile.isNotEmpty) {
        myNickname = cachedProfile.first['nickname'] as String? ?? '';
      }
      if (!mounted) return;
      setState(() {});
      channel = repository!.remote.listen(() {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 400), () => refresh());
      });
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = chatError(app, e));
    }
  }

  void schedule() {
    timer?.cancel();
    if (!mounted || !active) return;
    timer = Timer(
      Duration(
        seconds: failures == 0
            ? 20
            : [5, 15, 30, 60][(failures - 1).clamp(0, 3)],
      ),
      () => refresh(),
    );
  }

  void liveChanged() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() async {
    final repo = repository;
    if (repo == null || busy || !mounted || !active) return;
    setState(() => busy = true);
    try {
      Object? sendError;
      final revision = nicknameRevision;
      try {
        final number = await repo.remote.ownNumber();
        if (mounted) setState(() => myNumber = number);
      } catch (_) {}
      if (!savingNickname) {
        try {
          final name = await repo.remote.ownNickname();
          if (mounted && revision == nicknameRevision && name != null) {
            await repo.store.write('own_profile', [
              {'nickname': name},
            ]);
            if (mounted && revision == nicknameRevision) {
              setState(() => myNickname = name);
            }
          }
        } catch (e) {
          sendError = e;
        }
      }
      try {
        await repo.flush();
      } catch (e) {
        sendError = e;
      }
      final list = await repo.rooms();
      views = await repo.store.roomViews();
      final directory = ChatRepository.rows(
        await repo.remote.call('directory', {'search': search}),
      );
      try {
        await live!.heartbeat([
          ...directory.map((p) => p['user_id'] as String),
          ...live!.peers.values.cast<String>(),
        ]);
        liveError = null;
      } catch (e) {
        liveError = tr(
          '在线状态与直传服务未连接，请检查网络或执行 013 配置。',
          'Presence and direct transfers unavailable. Check network or migration 013.',
        );
      }
      if (!mounted) return;
      setState(() {
        rooms = list;
        people = directory;
        error = sendError == null ? null : chatError(app, sendError);
        failures = sendError == null ? 0 : failures + 1;
      });
      emitUnread();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = chatError(app, e);
          failures++;
        });
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        schedule();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) {
      refresh();
    } else {
      timer?.cancel();
      unawaited(live?.offline());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    debounce?.cancel();
    live?.removeListener(liveChanged);
    live?.dispose();
    if (channel != null) unawaited(widget.client.removeChannel(channel!));
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    try {
      await work();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = chatError(app, e));
    }
  }

  Future<void> open(Map<String, dynamic> room) async {
    if (repository == null || !mounted) return;
    await repository!.store.patchRoom(room['id'] as String, {
      'manualUnread': false,
      'hiddenThrough': null,
    });
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChatRoomPage(
          app: app,
          repository: repository!,
          room: room,
          live: live,
        ),
      ),
    );
    await refresh();
  }

  Future<void> nickname() async {
    if (savingNickname || repository == null) return;
    final name = await chatText(
      context,
      tr('我的聊天昵称', 'My chat name'),
      initial: myNickname,
      maxLength: 40,
    );
    if (name == null || name.isEmpty || !mounted) return;
    final repo = repository!;
    setState(() => savingNickname = true);
    nicknameRevision++;
    try {
      await repo.remote.call('profile', {'nickname': name});
      await repo.store.write('own_profile', [
        {'nickname': name},
      ]);
      if (mounted) {
        setState(() {
          myNickname = name;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = chatError(app, e));
    } finally {
      nicknameRevision++;
      if (mounted) setState(() => savingNickname = false);
    }
  }

  Future<void> contacts(String mode) async {
    if (repository == null) return;
    if (mode == 'profile_settings') {
      await ownStatusMenu();
      return;
    }
    if (mode == 'display') {
      final selected = await showModalBottomSheet<bool>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in [false, true])
                ListTile(
                  leading: Icon(
                    value ? Icons.grid_view : Icons.view_list_outlined,
                  ),
                  title: Text(value ? tr('网格', 'Grid') : tr('列表', 'List')),
                  trailing: gridMode == value ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(ctx, value),
                ),
            ],
          ),
        ),
      );
      if (selected != null && mounted) {
        setState(() => gridMode = selected);
        await (await SharedPreferences.getInstance()).setBool(
          'chat.grid.${widget.userId}',
          selected,
        );
      }
      return;
    }
    if (mode == 'scan') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScanPage(remote: repository!.remote),
        ),
      );
      await refresh();
      return;
    }
    if (mode == 'privacy') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(builder: (_) => ChatPrivacyPage(app: app)),
      );
      return;
    }
    final room = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatContactsPage(
          app: app,
          repository: repository!,
          rooms: rooms,
          mode: mode,
          onProfile: ownStatusMenu,
          live: live,
        ),
      ),
    );
    if (room != null && mounted) await open(room);
    await refresh();
  }

  Map<String, Map<String, dynamic>> views = {};
  void emitUnread() {
    final count = visibleChatRooms(
      rooms,
      views,
    ).fold<int>(0, (sum, r) => sum + roomUnread(r, views[r['id']]));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onUnreadChanged?.call(count);
    });
  }

  bool changingPresence = false;
  Future<void> guestBenefits() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('访客功能说明', 'Guest access')),
      content: Text(
        tr(
          '无需注册即可聊天、添加好友和加入群聊。\n\n注册并登录后可使用：\n• 隐身\n• 下载公共网盘资料\n• 计数数据同步\n• 笔记同步\n\n访客的计数与笔记仍保存在本机。',
          'Guests can chat, add friends and join groups.\n\nRegister and sign in to use invisible status, public-resource downloads, counter sync and notes sync.\n\nGuest counts and notes remain on this device.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('知道了', 'OK')),
        ),
      ],
    ),
  );
  Future<void> ownStatusMenu() async {
    if (repository == null || changingPresence) return;
    final guest = widget.client.auth.currentUser?.isAnonymous == true;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(tr('个人主页', 'Personal profile')),
                onTap: () => Navigator.pop(ctx, 'profile'),
              ),
              ListTile(
                title: Text(
                  myNickname.isEmpty ? tr('我的聊天昵称', 'My nickname') : myNickname,
                ),
              ),
              ListTile(
                title: SelectableText(
                  '${tr('个人号', 'Personal number')}：${myNumber ?? tr('联网后自动分配', 'Assigned when online')}',
                ),
                subtitle: Text(
                  tr(
                    '号码固定，昵称可修改。访客清除数据或卸载后可能无法找回，请绑定账号。',
                    'Your number is fixed; your nickname can change. Link an account to retain your guest identity after reinstalling.',
                  ),
                ),
              ),
              if (guest)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.info_outline),
                  title: Text(
                    tr('访客模式 · 注册解锁更多功能', 'Guest mode · Account benefits'),
                  ),
                  onTap: () => Navigator.pop(ctx, 'guest_info'),
                ),
              ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: const Text('添加好友设置'),
                onTap: () => Navigator.pop(ctx, 'friend_setting'),
              ),
              ListTile(
                leading: const PresenceLamp(lit: true),
                title: Text(tr('在线', 'Online')),
                trailing: live?.invisible == false
                    ? const Icon(Icons.check)
                    : null,
                onTap: live == null ? null : () => Navigator.pop(ctx, 'online'),
              ),
              ListTile(
                leading: const PresenceLamp(lit: false),
                title: Text(tr('隐身', 'Invisible')),
                subtitle: Text(
                  tr(
                    guest ? '注册并登录后可使用' : '本设备不显示在线，仍可收发消息',
                    guest
                        ? 'Register and sign in to use'
                        : 'Hide this device’s presence; messaging stays available',
                  ),
                ),
                trailing: live?.invisible == true
                    ? const Icon(Icons.check)
                    : null,
                onTap: guest
                    ? () => Navigator.pop(ctx, 'guest_info')
                    : live == null
                    ? null
                    : () => Navigator.pop(ctx, 'invisible'),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(tr('更换头像', 'Change avatar')),
                onTap: () => Navigator.pop(ctx, 'avatar'),
              ),
              ListTile(
                leading: const Icon(Icons.qr_code),
                title: Text(tr('我的二维码', 'My QR code')),
                onTap: () => Navigator.pop(ctx, 'qr'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(tr('修改昵称', 'Edit nickname')),
                onTap: () => Navigator.pop(ctx, 'nickname'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'profile') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PublicProfilePage(app: app, userId: widget.userId),
        ),
      );
    } else if (choice == 'friend_setting') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatFriendSettingPage(remote: repository!.remote),
        ),
      );
    } else if (choice == 'guest_info') {
      await guestBenefits();
    } else if (choice == 'qr') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatQrPage(
            remote: repository!.remote,
            title: myNickname.isEmpty ? tr('我的二维码', 'My QR code') : myNickname,
          ),
        ),
      );
    } else if (choice == 'avatar') {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ChatAvatarPage(app: app, remote: repository!.remote),
        ),
      );
      if (mounted) setState(() {});
    } else if (choice == 'nickname') {
      await nickname();
    } else {
      setState(() => changingPresence = true);
      try {
        final invisible = choice == 'invisible';
        await live!.setInvisible(invisible);
        await repository!.store.write('presence_preference', [
          {'invisible': invisible},
        ]);
      } catch (e) {
        if (mounted) {
          setState(
            () => error = tr(
              '状态更新失败，请检查网络后重试。其他设备的在线显示可能需要稍后刷新。',
              'Status update failed. Check your connection and retry. Other devices may take a moment to refresh.',
            ),
          );
        }
      } finally {
        if (mounted) setState(() => changingPresence = false);
      }
    }
  }

  Future<void> roomMenu(Map<String, dynamic> room) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(room['title'] as String)),
            ListTile(
              title: Text(
                room['pinned'] == true ? tr('取消置顶', 'Unpin') : tr('置顶', 'Pin'),
              ),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              title: Text(tr('标记未读', 'Mark unread')),
              onTap: () => Navigator.pop(ctx, 'unread'),
            ),
            ListTile(
              title: Text(
                room['muted'] == true
                    ? tr('关闭免打扰', 'Unmute')
                    : tr('消息免打扰', 'Mute'),
              ),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              title: Text(tr('删除会话', 'Delete conversation')),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              title: Text(tr('清空本机聊天记录', 'Clear local history')),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await action(() async {
      if (choice == 'pin' || choice == 'mute') {
        await repository!.remote.call('preferences', {
          'room_id': room['id'],
          if (choice == 'pin') 'pinned': room['pinned'] != true,
          if (choice == 'mute') 'muted': room['muted'] != true,
        });
      } else if (choice == 'unread') {
        await repository!.store.patchRoom(room['id'] as String, {
          'manualUnread': true,
        });
      } else if (choice == 'clear') {
        await clearLocalChat(context, app, repository!, room['id'] as String);
      } else if (choice == 'delete') {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('从本机会话列表移除？', 'Remove from this device’s list?')),
            content: Text(
              tr(
                '聊天记录和草稿保留，不影响对方。收到新消息或重新发起聊天后会重新显示。',
                'Messages and drafts are retained. New messages or reopening the chat restore it.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('取消', 'Cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('移除', 'Remove')),
              ),
            ],
          ),
        );
        if (yes == true) {
          await repository!.store.patchRoom(room['id'] as String, {
            'hiddenThrough':
                room['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
            'manualUnread': false,
          });
        }
      }
      views = await repository!.store.roomViews();
      if (mounted) setState(() {});
      emitUnread();
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversations = visibleChatRooms(rooms, views);
    // Same size range and corner ratio as the counter project icons.
    final avatarSize = ((MediaQuery.sizeOf(context).height - 180) / 6 - 8)
        .clamp(36.0, 56.0) * .9;
    Widget avatar(Map<String, dynamic> room) => room['kind'] == 'group'
        ? Container(
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(avatarSize * .22),
            ),
            child: Icon(Icons.groups_outlined, size: avatarSize * .55),
          )
        : ChatAvatar(
            remote: repository?.remote,
            roomId: room['id'] as String,
            userId: live?.peers[room['id']],
            radius: avatarSize / 2,
            cornerRadius: avatarSize * .22,
          );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: ChatTopBar(
          onProfile: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  PublicProfilePage(app: app, userId: widget.userId),
            ),
          ),
          english: app.english,
          onContacts: repository == null ? null : () => contacts('directory'),
          onResources: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CloudDrivePage(
                app: app,
                settingsPage: StorageStatusPage(app: app),
              ),
            ),
          ),
          onSearch: repository == null ? null : () => contacts('search'),
          onAdd: repository == null ? null : contacts,
        ),
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (liveError != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                liveError!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
          if (live != null) TransferInbox(app: app, live: live!),
          ListenableBuilder(
            listenable: Listenable.merge([AssistantManager.instance, BroadcastInbox.instance]),
            builder: (context, _) {
              final m = AssistantManager.instance;
              final unreadBroadcasts = BroadcastInbox.instance.unreadCount;
              final running = m.sessions.values.where((s) => !s.ended).length;
              final badgeCount = m.offers.length + unreadBroadcasts;
              return ListTile(
                key: const ValueKey('chat-file-assistant'),
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Badge(
                  isLabelVisible: badgeCount > 0,
                  label: Text('$badgeCount'),
                  child: const Icon(Icons.devices_other),
                ),
                title: Text(tr('文件传输助手', 'File transfer assistant')),
                subtitle: Text(
                  unreadBroadcasts > 0
                      ? tr('有 $unreadBroadcasts 个后台发送的新文件', '$unreadBroadcasts new from admin')
                      : m.offers.isNotEmpty
                      ? tr('有 ${m.offers.length} 个文件等待接收', '${m.offers.length} incoming')
                      : running > 0
                      ? tr('$running 个传输进行中', '$running running')
                      : tr('手机 ↔ 电脑大文件直传，不占云端空间', 'Phone ↔ PC, direct, no cloud storage'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => FileAssistantPage(app: app)),
                ),
              );
            },
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: gridMode && conversations.isNotEmpty
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final scale =
                            MediaQuery.textScalerOf(context).scale(16) / 16;
                        final columns =
                            (constraints.maxWidth / (130 * scale.clamp(1, 1.6)))
                                .floor()
                                .clamp(2, 6);
                        return GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: avatarSize + 20 + 48 * scale,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: conversations.length,
                          itemBuilder: (context, i) {
                            final room = conversations[i];
                            return InkWell(
                              onTap: () => open(room),
                              onLongPress: () => roomMenu(room),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Badge(
                                    isLabelVisible:
                                        roomUnread(room, views[room['id']]) > 0,
                                    child: avatar(room),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    room['title'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 18 * .85),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: conversations.isEmpty
                          ? 1
                          : conversations.length,
                      itemBuilder: (context, index) {
                        if (conversations.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              tr(
                                '暂无会话。点击右上角 + 发起聊天或添加好友。',
                                'No conversations. Tap + to start a chat or add a friend.',
                              ),
                            ),
                          );
                        }
                        final room = conversations[index],
                            view = views[room['id']];
                        final unread = roomUnread(room, view),
                            draft = view?['draft'] as String? ?? '';
                        return Dismissible(
                          key: ValueKey('room-actions:${room['id']}'),
                          direction: DismissDirection.startToEnd,
                          background: Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(left: 20),
                            color: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                            child: Row(
                              children: [
                                const Icon(Icons.push_pin_outlined),
                                const SizedBox(width: 8),
                                Text(tr('置顶 · 删除 · 更多', 'Pin · Delete · More')),
                              ],
                            ),
                          ),
                          confirmDismiss: (_) async {
                            await roomMenu(room);
                            return false;
                          },
                          child: ListTile(
                            dense: false,
                            minVerticalPadding: 2,
                            horizontalTitleGap: 10,
                            minLeadingWidth: avatarSize,
                            titleTextStyle: Theme.of(
                              context,
                            ).textTheme.titleLarge?.copyWith(fontSize: 23 * .85),
                            subtitleTextStyle: Theme.of(
                              context,
                            ).textTheme.bodyLarge?.copyWith(fontSize: 18 * .85),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 0,
                            ),
                            tileColor: room['pinned'] == true
                                ? Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest
                                : null,
                            leading: Badge(
                              isLabelVisible: unread > 0,
                              label: room['muted'] == true
                                  ? null
                                  : Text(unread > 99 ? '99+' : '$unread'),
                              child: avatar(room),
                            ),
                            title: room['kind'] == 'group'
                                ? Text(
                                    room['title'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : OnlineName(
                                    name: room['title'] as String,
                                    online: live?.known == true
                                        ? live!.online.contains(
                                            live!.peers[room['id']],
                                          )
                                        : null,
                                    english: tr('中', 'en') == 'en',
                                  ),
                            subtitle: Text(
                              draft.isNotEmpty
                                  ? '${tr('[草稿]', '[Draft]')} $draft'
                                  : chatPreview(room, view),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: draft.isNotEmpty
                                  ? TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    )
                                  : null,
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  chatListTime(room['updated_at']),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                                if (room['muted'] == true)
                                  const Icon(
                                    Icons.notifications_off_outlined,
                                    size: 15,
                                  ),
                              ],
                            ),
                            onTap: () => open(room),
                            onLongPress: () => roomMenu(room),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
