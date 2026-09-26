import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/chat_store.dart';
import '../data/remote/chat_remote.dart';
import '../data/repositories/chat_repository.dart';
import '../domain/forum_share.dart';
import 'chat_room_page.dart';
import 'jieyuan_fields.dart';
import 'forum_page.dart';

class JieyuanActions extends StatefulWidget {
  const JieyuanActions({super.key, required this.app, required this.post});
  final AppController app;
  final Map<String, dynamic> post;
  @override
  State<JieyuanActions> createState() => _JieyuanActionsState();
}

class _JieyuanActionsState extends State<JieyuanActions> {
  bool busy = false;
  Future<void> inquire() async {
    setState(() => busy = true);
    try {
      final client = widget.app.cloud!.client!;
      final user = client.auth.currentUser;
      if (user == null) throw StateError('用户身份尚未就绪');
      final p = await client.rpc(
        'jieyuan_inquire',
        params: {'p_id': widget.post['id']},
      );
      final remote = ChatRemote(client, user.id);
      final room = await remote.call('direct', {
        'user_id': p['author_user_id'],
      });
      final repo = ChatRepository(await ChatStore.open(user.id), remote);
      remote.checkUser();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatRoomPage(
            app: widget.app,
            repository: repo,
            room: {
              'id': room['id'],
              'kind': 'direct',
              'title': widget.post['author_name'],
            },
            initialSharedText: forumShareText(
              widget.post['id'],
              '${p['title']} · ${jieyuanSummary(p['jieyuan'])}',
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂不能发起结缘，请确认已登录、物品仍可结缘及聊天权限。')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> report() async {
    final text = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('举报结缘内容'),
        content: TextField(
          controller: text,
          maxLength: 1000,
          decoration: const InputDecoration(hintText: '请说明违规原因'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, text.text.trim()),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await widget.app.cloud!.client!.rpc(
        'jieyuan_report',
        params: {'p_id': widget.post['id'], 'p_reason': reason},
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('举报已提交')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('举报未提交，请登录后重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final j = widget.post['jieyuan'] as Map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${j['country'] ?? ''} · ${j['region'] ?? ''}  数量：${j['quantity']}',
        ),
        Text(
          '新旧：${{'new': '全新', 'like_new': '近新', 'used': '使用过'}[j['condition']]} · ${{'meet': '当面结缘', 'post': '可以邮寄', 'both': '当面或邮寄'}[j['delivery']]} · ${{'included': '包邮', 'extra': '邮费另计', 'discuss': '邮费协商'}[j['postage']]}',
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed:
                  busy ||
                      j['status'] == 'completed' ||
                      widget.post['owned'] == true
                  ? null
                  : inquire,
              child: Text(j['status'] == 'completed' ? '已结缘' : '我要结缘'),
            ),
            TextButton(onPressed: report, child: const Text('举报')),
          ],
        ),
      ],
    );
  }
}

class MyJieyuanPage extends StatelessWidget {
  const MyJieyuanPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('我的结缘'),
        bottom: const TabBar(
          tabs: [
            Tab(text: '我发布的'),
            Tab(text: '我收藏的'),
            Tab(text: '已结缘'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          ForumPage(app: app, category: 'jieyuan', initialSort: 'mine'),
          ForumPage(app: app, category: 'jieyuan', initialSort: 'bookmarks'),
          ForumPage(app: app, category: 'jieyuan', initialSort: 'completed'),
        ],
      ),
    ),
  );
}
