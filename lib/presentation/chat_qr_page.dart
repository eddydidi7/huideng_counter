import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../domain/chat_qr.dart';
import '../data/remote/chat_remote.dart';
import '../services/group_operation_error.dart';
import 'chat_page.dart' show chatText;

String chatQrError(Object error) {
  final group = groupAdminMessage(error);
  if (group != null) return group;
  final message = error.toString();
  if (message.contains('PGRST202')) return '群二维码尚未启用，请管理员完成 020 配置。';
  if (message.contains('ASK_GROUP_OWNER_FOR_QR')) return '请群主先生成或更新群二维码。';
  if (message.contains('ASK_GROUP_OWNER_TO_INVITE')) return '您已离开此群，请联系群主重新邀请。';
  if (message.contains('QR_EXPIRED') || message.contains('QR_UNAVAILABLE')) {
    return '二维码已失效，请获取最新的群二维码。';
  }
  if (message.contains('GROUP_FULL')) return '群人数已满，暂时无法加入。';
  if (message.contains('CHAT_BLOCKED')) return '当前无法通过此二维码加入群聊。';
  if (message.contains('Bad state: self')) return '这是您自己的二维码。';
  return '暂时无法操作，请检查网络及好友或群权限后重试。';
}

Future<dynamic> chatQrRpc(
  ChatRemote remote,
  String action,
  Map<String, dynamic> data,
) async {
  remote.checkUser();
  if (remote.client.auth.currentSession?.isExpired ?? true) {
    await remote.client.auth.refreshSession();
  }
  remote.checkUser();
  final result = await remote.client
      .rpc('chat_qr_v1', params: {'p_action': action, 'p_data': data})
      .timeout(const Duration(seconds: 20));
  remote.checkUser();
  return result;
}

class ChatQrPage extends StatefulWidget {
  const ChatQrPage({
    super.key,
    required this.remote,
    required this.title,
    this.roomId,
    this.owner = false,
  });
  final ChatRemote remote;
  final String title;
  final String? roomId;
  final bool owner;
  @override
  State<ChatQrPage> createState() => _ChatQrPageState();
}

class _ChatQrPageState extends State<ChatQrPage> {
  ChatQr? code;
  String? error, expires;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool rotate = false}) async {
    setState(() {
      busy = true;
      error = null;
      code = null;
    });
    try {
      widget.remote.checkUser();
      if (widget.roomId == null) {
        code = ChatQr('contact', widget.remote.userId);
      } else {
        final result = await chatQrRpc(
          widget.remote,
          rotate ? 'rotate' : 'code',
          {'room_id': widget.roomId},
        );
        code = ChatQr('group', result['token'] as String);
        expires = result['expires_at'] == null
            ? null
            : DateTime.parse(
                result['expires_at'] as String,
              ).toLocal().toString().substring(0, 16);
      }
    } catch (e) {
      error = chatQrError(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.roomId == null ? '我的二维码' : '群二维码')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            if (busy) const CircularProgressIndicator(),
            if (error != null) ...[
              Text(error!),
              TextButton(onPressed: load, child: const Text('重试')),
            ],
            if (code != null) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: QrImageView(
                    data: code!.value,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(20),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.roomId == null ? '使用文殊计数器扫一扫，添加好友' : '使用文殊计数器扫一扫，确认加入群聊',
              ),
              if (widget.roomId != null)
                Text(expires == null ? '永久有效（群主更新后旧码失效）' : '有效期至 $expires'),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code!.value));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制二维码内容，可分享或粘贴识别')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制二维码内容'),
              ),
              if (widget.roomId != null && widget.owner)
                TextButton(
                  onPressed: () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('更新群二维码？'),
                        content: const Text('原二维码将立即失效。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('更新'),
                          ),
                        ],
                      ),
                    );
                    if (yes == true && mounted) await load(rotate: true);
                  },
                  child: const Text('更新二维码'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

class ChatScanPage extends StatefulWidget {
  const ChatScanPage({super.key, required this.remote});
  final ChatRemote remote;
  @override
  State<ChatScanPage> createState() => _ChatScanPageState();
}

class _ChatScanPageState extends State<ChatScanPage> {
  bool busy = false;
  String? error;
  Future<void> detect(String value) async {
    if (busy || !mounted) return;
    final code = ChatQr.parse(value);
    if (code == null) {
      setState(() => error = '请扫描文殊计数器的好友或群二维码');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      String title;
      if (code.kind == 'contact') {
        if (code.id == widget.remote.userId) throw StateError('self');
        final rows =
            await widget.remote.contacts('search', {'query': code.id}) as List;
        if (rows.isEmpty) throw StateError('unavailable');
        title = rows.first['nickname'] as String;
      } else {
        final result = await chatQrRpc(widget.remote, 'resolve', {
          'token': code.id,
        });
        title = result['title'] as String;
      }
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(code.kind == 'contact' ? '添加好友' : '加入群聊'),
          content: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      var friendMessage = '添加已处理，请在通讯录查看';
      if (code.kind == 'contact') {
        await widget.remote.contacts('request', {
          'user_id': code.id,
          'note': '通过二维码添加',
        });
        try {
          final contacts = await widget.remote.contacts('list');
          friendMessage =
              (contacts['friends'] as List).any((p) => p['user_id'] == code.id)
              ? '已添加为好友'
              : '好友申请已发送，等待对方同意';
        } catch (_) {}
      } else {
        try {
          await chatQrRpc(widget.remote, 'join', {'token': code.id});
          friendMessage = '已加入群聊';
        } catch (e) {
          // Approval groups: submit a join request for the managers instead.
          if (!e.toString().contains('GROUP_APPROVAL_REQUIRED') || !mounted) rethrow;
          final note = await chatText(context, '入群申请留言（可不填）', maxLength: 200);
          if (note == null) return;
          await widget.remote.client.rpc('group_admin_v1', params: {
            'p_action': 'request_join',
            'p_data': {'token': code.id, 'message': note.trim()},
          });
          friendMessage = '已提交入群申请，等待群主或管理员审核';
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendMessage)),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = chatQrError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫一扫')),
    body: Column(
      children: [
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : (kIsWeb ||
                    [
                      TargetPlatform.android,
                      TargetPlatform.iOS,
                      TargetPlatform.macOS,
                    ].contains(defaultTargetPlatform))
              ? MobileScanner(
                  onDetect: (capture) {
                    for (final b in capture.barcodes) {
                      if (b.rawValue != null) {
                        detect(b.rawValue!);
                        break;
                      }
                    }
                  },
                  errorBuilder: (_, _) =>
                      const Center(child: Text('无法使用相机，请开启相机权限，或粘贴二维码内容')),
                )
              : const Center(child: Text('此设备可粘贴二维码内容识别')),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        SafeArea(
          top: false,
          child: TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (mounted) await detect(data?.text ?? '');
                  },
            icon: const Icon(Icons.content_paste),
            label: const Text('粘贴二维码内容'),
          ),
        ),
      ],
    ),
  );
}
