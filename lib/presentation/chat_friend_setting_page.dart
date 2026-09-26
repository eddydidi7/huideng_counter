import 'package:flutter/material.dart';
import '../data/remote/chat_remote.dart';

class ChatFriendSettingPage extends StatefulWidget {
  const ChatFriendSettingPage({super.key, required this.remote});
  final ChatRemote remote;
  @override
  State<ChatFriendSettingPage> createState() => _ChatFriendSettingPageState();
}

class _ChatFriendSettingPageState extends State<ChatFriendSettingPage> {
  bool? requiredApproval;
  bool busy = false;
  String? error;
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
      widget.remote.checkUser();
      final result = await widget.remote.client
          .rpc('chat_friend_setting_v1', params: {'p_value': value})
          .timeout(const Duration(seconds: 20));
      widget.remote.checkUser();
      if (mounted) {
        setState(
          () => requiredApproval = result['require_friend_approval'] as bool,
        );
      }
    } catch (_) {
      if (mounted) setState(() => error = '设置未能读取或保存，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('添加好友设置')),
    body: ListView(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          ListTile(
            title: Text(error!),
            trailing: TextButton(
              onPressed: busy ? null : () => load(),
              child: const Text('重试'),
            ),
          ),
        SwitchListTile(
          title: const Text('加好友需要我同意'),
          subtitle: const Text('默认关闭：别人添加你时直接成为好友。开启后：需要你同意好友申请。设置随账号保存。'),
          value: requiredApproval ?? false,
          onChanged: busy || requiredApproval == null ? null : load,
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('此设置针对别人添加你；你添加别人时，以对方的设置为准。已有待处理申请仍需手动处理，黑名单继续生效。'),
        ),
      ],
    ),
  );
}
