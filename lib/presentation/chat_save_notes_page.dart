import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../services/content_transfer.dart';

class ChatSaveNotesPage extends StatefulWidget {
  const ChatSaveNotesPage({
    super.key,
    required this.app,
    required this.room,
    required this.title,
    required this.messages,
    required this.members,
    this.initialId,
  });
  final AppController app;
  final String room, title;
  final String? initialId;
  final List<Map<String, dynamic>> messages, members;
  @override
  State<ChatSaveNotesPage> createState() => _ChatSaveNotesPageState();
}

class _ChatSaveNotesPageState extends State<ChatSaveNotesPage> {
  late final selected = <String>{
    if (widget.initialId != null) widget.initialId!,
  };
  bool saving = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('合并保存到笔记'),
      actions: [
        TextButton(
          onPressed: saving || selected.isEmpty
              ? null
              : () async {
                  setState(() => saving = true);
                  try {
                    await ContentTransfer(widget.app).messagesToNote(
                      widget.room,
                      widget.title,
                      widget.messages
                          .where((m) => selected.contains(m['id']))
                          .toList(),
                      widget.members,
                    );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
                    }
                  } finally {
                    if (mounted) setState(() => saving = false);
                  }
                },
          child: Text('保存 (${selected.length})'),
        ),
      ],
    ),
    body: ListView(
      children: [
        const ListTile(
          subtitle: Text('选择已加载的消息。按原顺序保存发送者、时间和附件引用；引用仍遵守原会话权限。'),
        ),
        for (final m in widget.messages)
          if (m['recalled_at'] == null && m['call_record'] != true)
            CheckboxListTile(
              value: selected.contains(m['id']),
              onChanged: saving
                  ? null
                  : (v) => setState(() {
                      if (v == true) {
                        selected.add(m['id']);
                      } else {
                        selected.remove(m['id']);
                      }
                    }),
              title: Text(
                '${m['body'] ?? ''}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${m['created_at']}'),
            ),
      ],
    ),
  );
}
