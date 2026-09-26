import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/repositories/chat_repository.dart';

/// A per-account display boundary, never a destructive server deletion.
Future<bool> clearLocalChat(
  BuildContext context,
  AppController app,
  ChatRepository repository,
  String room,
) async {
  String tr(String zh, String en) => app.text(zh, en);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('清空本机聊天记录？', 'Clear chat on this device?')),
      content: Text(
        tr(
          '已有消息将从本机界面隐藏；云端、对方记录和待发送内容保留。可在“更多”中恢复显示。',
          'Existing messages will be hidden here. Cloud history, the other participant’s history and pending sends are retained. Restore them from More.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('取消', 'Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('清空本机记录', 'Clear local history')),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  var messages = await repository.store.read('messages:$room');
  try {
    messages = await repository.messages(room);
  } catch (e) {
    debugPrint('Clear chat uses cached boundary: ${e.runtimeType}');
  }
  final dates =
      messages
          .map((m) => DateTime.tryParse(m['created_at'] as String? ?? ''))
          .whereType<DateTime>()
          .toList()
        ..sort();
  if (dates.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '暂无已加载记录可清空，请先打开会话。',
              'No loaded history to clear. Open the conversation first.',
            ),
          ),
        ),
      );
    }
    return false;
  }
  repository.remote.checkUser();
  await repository.store.patchRoom(room, {
    'clearedThrough': dates.last.toUtc().toIso8601String(),
  });
  return true;
}
