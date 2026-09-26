import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/remote/chat_remote.dart';
import 'chat_page.dart';

class ChatPrivacyPage extends StatefulWidget {
  final AppController app;
  const ChatPrivacyPage({super.key, required this.app});
  @override
  State<ChatPrivacyPage> createState() => _ChatPrivacyPageState();
}

class _ChatPrivacyPageState extends State<ChatPrivacyPage> {
  bool? allow;
  bool busy = false;
  String? error;
  String tr(String zh, String en) => widget.app.text(zh, en);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load([bool? value]) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final client = widget.app.cloud?.client;
      final user = client?.auth.currentUser;
      if (client == null || user == null) {
        throw StateError('CHAT_LOGIN_REQUIRED');
      }
      final result = await ChatRemote(client, user.id).directory(
        value == null ? 'privacy' : 'privacy_set',
        value == null ? {} : {'allow_strangers': value},
      );
      if (mounted) setState(() => allow = result['allow_strangers'] as bool);
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('陌生人聊天开关', 'Stranger message settings'))),
    body: ListView(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          ListTile(
            title: Text(error!),
            trailing: IconButton(
              onPressed: () => load(),
              icon: const Icon(Icons.refresh),
            ),
          ),
        ListTile(
          title: Text(tr('陌生人聊天', 'Stranger messages')),
          subtitle: Text(
            tr(
              '设置随账号保存。关闭后仅好友可向你发送私聊消息，仍可收到好友申请。',
              'Saved to your account. Friends only when disabled; friend requests remain available.',
            ),
          ),
        ),
        if (allow != null)
          SwitchListTile(
            title: Text(tr('允许陌生人直接聊天', 'Allow messages from strangers')),
            subtitle: Text(
              allow!
                  ? tr('允许陌生人直接聊天', 'Anyone can message you')
                  : tr('仅好友可聊天', 'Friends only'),
            ),
            value: allow!,
            onChanged: busy ? null : (value) => load(value),
          ),
      ],
    ),
  );
}
