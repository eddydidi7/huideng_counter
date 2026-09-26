import '../domain/post_display.dart';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/chat_store.dart';
import '../data/local/home_message_cache.dart';
import '../data/remote/chat_remote.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/forum_repository.dart';
import '../domain/forum_share.dart';
import 'chat_page.dart';
import 'chat_room_page.dart';
import 'forum_page.dart';

/// [groups]: null lists every conversation, true only group chats and
/// false only one-to-one chats with friends.
Future<void> shareForumToChat(
  BuildContext context,
  AppController app,
  Map<String, dynamic> post, {
  bool? groups,
}) => shareTextToChat(
  context,
  app,
  forumShareText(
    post['id'] as String,
    getPostDisplayTitle(post),
    slug: post['share_slug'] as String?,
  ),
  groups: groups,
);

Future<void> shareTextToChat(
  BuildContext context,
  AppController app,
  String text, {
  bool? groups,
}) async {
  final client = app.cloud?.client;
  final user = client?.auth.currentUser;
  if (client == null || user == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(app.text('聊天身份尚未就绪', 'Chat identity is not ready')),
      ),
    );
    return;
  }
  try {
    final repo = ChatRepository(
      await ChatStore.open(user.id),
      ChatRemote(client, user.id),
    );
    final rooms = [
      for (final room in await repo.rooms())
        if (groups == null || (room['kind'] == 'group') == groups) room,
    ];
    repo.remote.checkUser();
    if (!context.mounted) return;
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  groups == null
                      ? app.text('选择聊天 · 进入后点击发送', 'Choose chat · tap Send to share')
                      : groups
                      ? app.text('选择群聊 · 进入后点击发送', 'Choose group · tap Send')
                      : app.text('选择好友 · 进入后点击发送', 'Choose friend · tap Send'),
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    if (rooms.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          groups == true
                              ? app.text('暂无群聊，请先到聊天中创建或加入群聊', 'No group chats yet.')
                              : app.text(
                                  '暂无会话，请先到聊天中添加好友或创建群聊',
                                  'No conversations. Start a chat first.',
                                ),
                        ),
                      ),
                    for (final room in rooms)
                      ListTile(
                        leading: Icon(
                          room['kind'] == 'group'
                              ? Icons.groups_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(room['title'] as String? ?? ''),
                        onTap: () => Navigator.pop(ctx, room),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    repo.remote.checkUser();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChatRoomPage(
          app: app,
          repository: repo,
          room: selected,
          initialSharedText: text,
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(chatError(app, e))));
    }
  }
}

class SharedForumMessage extends StatelessWidget {
  const SharedForumMessage({super.key, required this.app, required this.text});
  final AppController app;
  final String text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        text.replaceAll(RegExp(r'huideng://forum/post/[^\s]+'), '').trim(),
        style: const TextStyle(fontSize: 18, height: 1.4),
      ),
      TextButton.icon(
        icon: const Icon(Icons.article_outlined),
        label: Text(app.text('查看红书帖子', 'Open post')),
        onPressed: () {
          final client = app.cloud?.client;
          if (client == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  app.text(
                    '内容暂时无法加载，请检查网络配置',
                    'Content unavailable. Check connection settings.',
                  ),
                ),
              ),
            );
            return;
          }
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ForumDetailPage(
                app: app,
                row: {
                  'id': sharedForumPostId(text),
                  'share_slug': sharedForumSlug(text),
                },
                repository: ForumRepository(
                  ForumRemote(client),
                  HomeMessageCache(cacheKey: 'forum_feed'),
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}
