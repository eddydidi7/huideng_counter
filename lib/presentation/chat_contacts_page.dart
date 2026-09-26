import '../domain/chat_identity.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../data/repositories/chat_repository.dart';
import 'chat_page.dart';
import 'chat_avatar.dart';
import '../data/remote/chat_live.dart';

class ChatContactsPage extends StatefulWidget {
  final AppController app;
  final ChatRepository repository;
  final List<Map<String, dynamic>> rooms;
  final String mode;
  final ChatLive? live;
  final VoidCallback? onProfile;
  const ChatContactsPage({
    super.key,
    required this.app,
    required this.repository,
    required this.rooms,
    this.mode = 'contacts',
    this.live,
    this.onProfile,
  });
  @override
  State<ChatContactsPage> createState() => _ChatContactsPageState();
}

class _ChatContactsPageState extends State<ChatContactsPage> {
  final query = TextEditingController();
  List<Map<String, dynamic>> friends = [], requests = [], results = [];
  List<Map<String, dynamic>> people = [];
  bool loadingPeople = false, hasMorePeople = true;
  String? directoryError;
  final selected = <String>{};
  String? error;
  bool busy = false, searching = false, submitting = false;
  int tab = 0;
  Timer? debounce;
  RealtimeChannel? channel;
  ChatRepository get repo => widget.repository;
  String tr(String a, String b) => widget.app.text(a, b);
  bool get group => widget.mode == 'group';
  Set<String> savedGroups = {};

  @override
  void initState() {
    super.initState();
    widget.live?.addListener(statusChanged);
    initialize();
    repo.store.roomViews().then((views) {
      if (!mounted) return;
      setState(
        () => savedGroups = {
          for (final e in views.entries)
            if (e.value['savedToContacts'] == true) e.key,
        },
      );
    }).catchError((Object _) {});
    channel = repo.remote.client
        .channel('friend-page:${const Uuid().v4()}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_friend_requests',
          callback: (_) => schedule(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_friends',
          callback: (_) => schedule(),
        )
        .subscribe();
  }

  void schedule() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 400), () => load());
  }

  void statusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> initialize() async {
    try {
      friends = await repo.store.read('friends');
    } catch (e) {
      debugPrint('Contacts cache: ${e.runtimeType}');
    }
    if (mounted) setState(() {});
    await load();
    if (!group) await loadPeople(reset: true);
  }

  Future<void> loadPeople({bool reset = false}) async {
    if (loadingPeople || !mounted) return;
    setState(() => loadingPeople = true);
    try {
      final page = ChatRepository.rows(
        await repo.remote.directory('directory', {
          if (!reset && people.isNotEmpty) 'after': people.last['user_id'],
        }),
      );
      if (mounted) {
        setState(() {
          people = reset ? page : [...people, ...page];
          hasMorePeople = page.length == 100;
          directoryError = null;
        });
      }
      try {
        await widget.live?.heartbeat(
          people.take(200).map((p) => p['user_id'] as String),
        );
      } catch (e) {
        debugPrint('Directory presence: ${e.runtimeType}');
      }
    } catch (e) {
      if (mounted) setState(() => directoryError = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => loadingPeople = false);
    }
  }

  @override
  void dispose() {
    widget.live?.removeListener(statusChanged);
    query.dispose();
    debounce?.cancel();
    if (channel != null) unawaited(repo.remote.client.removeChannel(channel!));
    super.dispose();
  }

  Future<void> load() async {
    if (busy || !mounted) return;
    setState(() => busy = true);
    try {
      final data = await repo.remote.contacts('list');
      final list = ChatRepository.rows(data['friends']);
      await repo.store.write('friends', list);
      try {
        await widget.live?.heartbeat(list.map((p) => p['user_id'] as String));
      } catch (e) {
        debugPrint('Contacts presence: ${e.runtimeType}');
      }
      if (mounted) {
        setState(() {
          friends = list;
          requests = ChatRepository.rows(data['requests']);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e.toString().contains('PGRST202')
              ? tr(
                  '好友服务未配置，请执行 014 好友配置脚本。',
                  'Friend service requires migration 014.',
                )
              : chatError(widget.app, e),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    if (query.text.trim().length < 2) {
      setState(
        () => error = tr(
          '请输入至少两个字符，或完整邮箱 / 用户ID。',
          'Enter at least two characters, or a full email / user ID.',
        ),
      );
      return;
    }
    if (submitting) return;
    setState(() => submitting = true);
    try {
      final values = ChatRepository.rows(
        await repo.remote.contacts('search', {'query': query.text.trim()}),
      );
      if (mounted) {
        setState(() {
          results = values;
          searching = true;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Future<void> act(String action, Map<String, dynamic> data) async {
    if (submitting) return;
    setState(() => submitting = true);
    try {
      await repo.remote.contacts(action, data);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Future<void> start(Map<String, dynamic> person) async {
    if (submitting) return;
    setState(() => submitting = true);
    try {
      final data = await repo.remote.call('direct', {
        'user_id': person['user_id'],
      });
      if (mounted) {
        Navigator.pop(context, {
          'id': data['id'],
          'kind': 'direct',
          'title': person['nickname'],
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Future<void> request(Map<String, dynamic> person) async {
    if (submitting) return;
    setState(() => submitting = true);
    bool requiresApproval;
    try {
      requiresApproval = await repo.remote.requiresFriendApproval(
        person['user_id'] as String,
      );
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
      return;
    } finally {
      if (mounted) setState(() => submitting = false);
    }
    if (!mounted) return;
    String note = '';
    if (requiresApproval) {
      final entered = await chatText(
        context,
        tr('好友验证消息（可留空）', 'Friend request message (optional)'),
        maxLength: 200,
      );
      if (entered == null || !mounted) return;
      note = entered;
    }
    await act('request', {'user_id': person['user_id'], 'note': note});
    if (mounted && error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friends.any((p) => p['user_id'] == person['user_id'])
                ? tr('已添加为好友', 'Friend added')
                : tr(
                    '好友申请已发送，等待对方同意',
                    'Friend request sent; awaiting approval',
                  ),
          ),
        ),
      );
    }
  }

  Future<void> profile(Map<String, dynamic> person) async {
    if (person['user_id'] == repo.remote.userId) return;
    final isFriend = friends.any((p) => p['user_id'] == person['user_id']);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatAvatar(
                remote: repo.remote,
                userId: person['user_id'] as String,
                radius: 28,
              ),
              Text(
                person['nickname'] as String,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              SelectableText(
                personalNumberLabel(person, english: widget.app.english),
              ),
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: person['personal_number']?.toString() ?? '',
                  ),
                ),
                child: Text(tr('复制个人号', 'Copy personal number')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'chat'),
                child: Text(tr('发消息', 'Message')),
              ),
              if (!isFriend)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'add'),
                  child: Text(tr('添加好友', 'Add friend')),
                ),
              if (isFriend)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'remove'),
                  child: Text(tr('删除好友', 'Remove friend')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'block'),
                child: Text(
                  person['blocked'] == true
                      ? tr('解除拉黑', 'Unblock')
                      : tr('拉黑', 'Block'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'chat') await start(person);
    if (choice == 'add') await request(person);
    if (!mounted) return;
    if (choice == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('删除好友？', 'Remove friend?')),
          content: Text(
            tr(
              '将解除双方好友关系，已有聊天记录保留。',
              'Removes the friendship for both accounts. Messages are retained.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消', 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('删除好友', 'Remove')),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await act('remove', {'user_id': person['user_id']});
      }
    }
    if (choice == 'block') {
      try {
        await repo.remote.call('block', {
          'user_id': person['user_id'],
          'blocked': person['blocked'] != true,
        });
        await load();
        await loadPeople(reset: true);
      } catch (e) {
        if (mounted) setState(() => error = chatError(widget.app, e));
      }
    }
  }

  Future<void> createGroup() async {
    if (submitting) return;
    setState(() => submitting = true);
    final title = await chatText(context, tr('群名称', 'Group name'));
    if (title == null || title.isEmpty || !mounted || selected.isEmpty) {
      if (mounted) setState(() => submitting = false);
      return;
    }
    try {
      final data = await repo.remote.call('create_group', {
        'id': const Uuid().v4(),
        'title': title,
        'members': selected.toList(),
      });
      if (mounted) {
        Navigator.pop(context, {
          'id': data['id'],
          'kind': 'group',
          'title': title,
          'owner_id': repo.remote.userId,
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listedPeople = group || tab == 1
        ? friends
        : people
              .where(
                (p) =>
                    tab == 0 ||
                    (p['user_id'] != repo.remote.userId &&
                        !friends.any((f) => f['user_id'] == p['user_id'])),
              )
              .toList();
    // Groups saved to contacts (a per-device choice) are listed first.
    final groups = widget.rooms
        .where(
          (r) =>
              r['kind'] == 'group' &&
              (query.text.trim().isEmpty ||
                  (r['title'] as String).toLowerCase().contains(
                    query.text.trim().toLowerCase(),
                  )),
        )
        .toList()
      ..sort(
        (a, b) => (savedGroups.contains(b['id']) ? 1 : 0).compareTo(
          savedGroups.contains(a['id']) ? 1 : 0,
        ),
      );
    final incoming = requests
        .where(
          (r) =>
              r['receiver_id'] == repo.remote.userId && r['state'] == 'pending',
        )
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          group
              ? tr('创建群聊', 'Create group')
              : widget.mode == 'search'
              ? tr('搜索', 'Search')
              : tr('通讯录 / 添加好友', 'Contacts / Add friend'),
        ),
        actions: [
          if (widget.onProfile != null)
            IconButton(
              tooltip: tr('我的头像与在线状态', 'My profile and presence'),
              onPressed: widget.onProfile,
              icon: const Icon(Icons.person_outline, color: Color(0xFF65BFFF)),
            ),
          IconButton(
            onPressed: () async {
              await load();
              await loadPeople(reset: true);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!group)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: query,
                onSubmitted: (_) => search(),
                decoration: InputDecoration(
                  hintText: tr('个人号 / 昵称 / 完整邮箱', 'Number / name / full email'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: submitting ? null : search,
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
              ),
            ),
          if (!group && !searching)
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(tr('全部用户', 'All users'))),
                ButtonSegment(value: 1, label: Text(tr('好友', 'Friends'))),
                ButtonSegment(value: 2, label: Text(tr('陌生人', 'Strangers'))),
              ],
              emptySelectionAllowed: true,
              selected: tab < 3 ? {tab} : {},
              onSelectionChanged: (v) {
                if (v.isNotEmpty) setState(() => tab = v.first);
              },
            ),
          if (!group && !searching)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => setState(() => tab = 3),
                  child: Text(tr('新的好友 ($incoming)', 'Requests ($incoming)')),
                ),
                TextButton(
                  onPressed: () => setState(() => tab = 4),
                  child: Text(tr('群聊', 'Groups')),
                ),
              ],
            ),
          if (busy || submitting || loadingPeople)
            const LinearProgressIndicator(),
          if (directoryError != null && !group && (tab == 0 || tab == 2))
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(directoryError!),
            ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          Expanded(
            child: ListView(
              children: [
                if (searching) ...[
                  ListTile(
                    title: Text(tr('联系人', 'Contacts')),
                    trailing: TextButton(
                      onPressed: () => setState(() {
                        searching = false;
                        query.clear();
                      }),
                      child: Text(tr('清除搜索', 'Clear')),
                    ),
                  ),
                  for (final person in results)
                    ListTile(
                      leading: ChatAvatar(
                        remote: repo.remote,
                        userId: person['user_id'] as String,
                      ),
                      title: Text(personalNumberLabel(person, english: widget.app.english)),
                      subtitle: Text(
                        person['nickname'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => profile(person),
                    ),
                  if (results.isEmpty)
                    ListTile(title: Text(tr('没有找到联系人', 'No contacts found'))),
                  ListTile(
                    title: Text(tr('群聊 / 会话', 'Groups / Conversations')),
                  ),
                  for (final r in widget.rooms.where(
                    (r) => (r['title'] as String).toLowerCase().contains(
                      query.text.trim().toLowerCase(),
                    ),
                  ))
                    ListTile(
                      title: Text(r['title'] as String),
                      onTap: () => Navigator.pop(context, r),
                    ),
                ] else if (tab < 3 || group) ...[
                  for (final p in listedPeople)
                    ListTile(
                      leading: group
                          ? Checkbox(
                              value: selected.contains(p['user_id']),
                              onChanged: p['blocked'] == true
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        selected.add(p['user_id'] as String);
                                      } else {
                                        selected.remove(p['user_id']);
                                      }
                                    }),
                            )
                          : ChatAvatar(
                              remote: repo.remote,
                              userId: p['user_id'] as String,
                            ),
                      title: OnlineName(
                        name: personalNumberLabel(p, english: widget.app.english),
                        online: widget.live?.known == true
                            ? widget.live!.online.contains(p['user_id'])
                            : null,
                        english: tr('中', 'en') == 'en',
                      ),
                      subtitle: p['blocked'] == true
                          ? Text(tr('已拉黑', 'Blocked'))
                          : Text(
                              '${p['nickname']}${p['user_id'] == repo.remote.userId ? tr('（我）', ' (me)') : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: group || p['user_id'] == repo.remote.userId
                          ? null
                          : () => profile(p),
                    ),
                  if (listedPeople.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        tr(
                          '暂无联系人，可搜索个人号、昵称或完整邮箱。',
                          'No contacts. Search by name, user ID or full email.',
                        ),
                      ),
                    ),
                  if (!group && tab != 1 && hasMorePeople)
                    TextButton(
                      onPressed: loadingPeople ? null : () => loadPeople(),
                      child: Text(tr('加载更多用户', 'Load more users')),
                    ),
                ] else if (tab == 3) ...[
                  for (final r in requests)
                    ListTile(
                      title: Text(r['nickname'] as String),
                      subtitle: Text(
                        '${r['note']}\n${r['state'] == 'pending'
                            ? tr('等待确认', 'Pending')
                            : r['state'] == 'accepted'
                            ? tr('已同意', 'Accepted')
                            : tr('已拒绝', 'Declined')}',
                      ),
                      trailing:
                          r['receiver_id'] == repo.remote.userId &&
                              r['state'] == 'pending'
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: tr('同意', 'Accept'),
                                  onPressed: submitting
                                      ? null
                                      : () => act('review', {
                                          'id': r['id'],
                                          'accept': true,
                                        }),
                                  icon: const Icon(Icons.check),
                                ),
                                IconButton(
                                  tooltip: tr('拒绝', 'Decline'),
                                  onPressed: submitting
                                      ? null
                                      : () => act('review', {
                                          'id': r['id'],
                                          'accept': false,
                                        }),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            )
                          : null,
                    ),
                  if (requests.isEmpty)
                    ListTile(title: Text(tr('暂无好友申请', 'No friend requests'))),
                ] else ...[
                  for (final r in groups)
                    ListTile(
                      leading: Icon(
                        savedGroups.contains(r['id'])
                            ? Icons.bookmark
                            : Icons.groups_outlined,
                      ),
                      title: Text(r['title'] as String),
                      onTap: () => Navigator.pop(context, r),
                    ),
                ],
              ],
            ),
          ),
          if (group)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: selected.isEmpty ? null : createGroup,
                  child: Text(
                    tr(
                      '创建群聊（${selected.length}人）',
                      'Create group (${selected.length})',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
