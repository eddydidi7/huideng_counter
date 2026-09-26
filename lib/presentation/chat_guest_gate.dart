import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatGuestGate extends StatefulWidget {
  const ChatGuestGate({super.key, required this.connect});
  final Future<void> Function() connect;
  @override
  State<ChatGuestGate> createState() => _ChatGuestGateState();
}

class _ChatGuestGateState extends State<ChatGuestGate> {
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) connect();
    });
  }

  Future<void> connect() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.connect();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is AuthException && e.code == 'anonymous_provider_disabled'
              ? '免注册聊天尚未开通，请管理员开启访客登录。'
              : '暂时无法连接聊天，请联网后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('聊天')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('正在连接聊天，无需注册…'),
            ] else ...[
              Text(error ?? '无需注册即可聊天'),
              TextButton(onPressed: connect, child: const Text('重试')),
            ],
          ],
        ),
      ),
    ),
  );
}
