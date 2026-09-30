import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/remote/chat_remote.dart';
import '../data/repositories/chat_repository.dart';
import 'chat_avatar.dart';
import '../domain/chat_identity.dart';
import '../services/group_operation_error.dart';
import 'package:uuid/uuid.dart';

class GroupInvitePage extends StatefulWidget {
  const GroupInvitePage({
    super.key,
    required this.app,
    required this.remote,
    required this.roomId,
    required this.memberIds,
    this.createFromDirect = false,
  });
  final ChatRemote remote;
  final AppController app;
  final String roomId;
  final Set<String> memberIds;
  final bool createFromDirect;
  @override
  State<GroupInvitePage> createState() => _GroupInviteState();
}

class _GroupInviteState extends State<GroupInvitePage> {
  final query = TextEditingController();
  final selected = <String>{};
  final newRoomId = const Uuid().v4();
  List<Map<String, dynamic>> people = [];
  bool busy = false, more = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> load({bool next = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final text = query.text.trim();
      final result = ChatRepository.rows(
        text.isEmpty
            ? await widget.remote.directory('directory', {
                if (next && people.isNotEmpty) 'after': people.last['user_id'],
              })
            : await widget.remote.contacts('search', {'query': text}),
      );
      if (mounted) {
        setState(() {
          people = next ? [...people, ...result] : result;
          more = text.isEmpty && result.length == 100;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '无法读取用户，请重试。');
      debugPrint('Group invite directory: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> invite() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      widget.remote.checkUser();
      if (widget.remote.client.auth.currentSession?.isExpired ?? true) {
        await widget.remote.client.auth.refreshSession();
      }
      final result = widget.createFromDirect
          ? await widget.remote.client.rpc(
              'group_manage_v2',
              params: {
                'p_action': 'from_direct',
                'p_data': {
                  'room_id': widget.roomId,
                  'id': newRoomId,
                  'users': selected.toList(),
                },
              },
            )
          : await widget.remote.client.rpc(
              'group_invite_v1',
              params: {'p_group': widget.roomId, 'p_users': selected.toList()},
            );
      widget.remote.checkUser();
      if (mounted) {
        if (!widget.createFromDirect && result['added'] == 0) {
          setState(() => error = '所选用户已经在群聊中');
        } else {
          Navigator.pop(context, widget.createFromDirect ? result : true);
        }
      }
    } catch (e) {
      debugPrint('Group invite: $e');
      if (mounted) setState(() => error = groupOperationError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('添加成员'),
      actions: [
        TextButton(
          onPressed: busy || selected.isEmpty ? null : invite,
          child: Text('添加 (${selected.length})'),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: query,
            onSubmitted: (_) => load(),
            decoration: InputDecoration(
              hintText: '搜索昵称、个人号',
              suffixIcon: IconButton(
                onPressed: busy ? null : load,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        Expanded(
          child: ListView(
            children: [
              for (final person in people)
                if (person['user_id'] != widget.remote.userId &&
                    !widget.memberIds.contains(person['user_id']))
                  CheckboxListTile(
                    secondary: ChatAvatar(
                      app: widget.app,
                      remote: widget.remote,
                      userId: person['user_id'],
                    ),
                    title: Text(person['nickname'] as String? ?? '学友'),
                    subtitle: Text(personalNumberLabel(person)),
                    value: selected.contains(person['user_id']),
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              selected.add(person['user_id'] as String);
                            } else {
                              selected.remove(person['user_id']);
                            }
                          }),
                  ),
              if (more)
                TextButton(
                  onPressed: busy ? null : () => load(next: true),
                  child: const Text('加载更多'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
