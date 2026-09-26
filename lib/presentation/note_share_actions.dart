import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/app_controller.dart';
import '../data/local/home_message_cache.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import 'forum_compose_page.dart';
import 'forum_page.dart';
import 'forum_chat_share.dart';
import 'note_rich_content.dart';

Future<void> shareReadingNote(
  BuildContext context,
  AppController app,
  String action, {
  required String id,
  required String title,
  required String body,
  bool storedNote = true,
}) async {
  if (action == 'chat') {
    return shareTextToChat(context, app, NoteRichContent.plainText(body));
  }
  final client = app.cloud?.client;
  if (client == null || client.auth.currentUser == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('请先登录；本地笔记仍保留。')));
    return;
  }
  if (action == 'redbook') {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ForumComposePage(
          app: app,
          repository: ForumRepository(
            ForumRemote(client),
            HomeMessageCache(cacheKey: 'forum_feed'),
          ),
          categories: forumCategories,
          initialTitle: title,
          initialBody: body,
          sourceNoteId: storedNote ? id : null,
        ),
      ),
    );
    return;
  }
  if (!storedNote) return;
  try {
    final data = await client.rpc(
      'note_web_link_v1',
      params: {
        'p_note': id,
        'p_action': action,
        if (action == 'publish') 'p_title': title,
        if (action == 'publish') 'p_body': NoteRichContent.plainText(body),
      },
    );
    final url = data['url'] as String?;
    if (url != null) await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'revoke'
                ? '公开链接已取消，原网址已失效。'
                : url == null
                ? '尚未生成网页链接。'
                : '网页链接已复制。分享的是当前正文副本。',
          ),
        ),
      );
    }
  } catch (e) {
    debugPrint('Note web link: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('链接操作未成功，请检查登录与网络后重试。私人笔记未更改。')),
      );
    }
  }
}
