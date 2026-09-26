import '../services/apk_files.dart';
import 'apk_file_card.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/remote/chat_live.dart';
import '../services/direct_transfer.dart';
import '../data/local/chat_store.dart';

Future<void> sendDirectFile(
  BuildContext context,
  AppController app,
  ChatLive live,
  String room,
  List<Map<String, dynamic>> members,
) async {
  String tr(String a, String b) => app.text(a, b);
  try {
    final targets = members
        .where((m) => m['user_id'] != live.remote.userId)
        .toList();
    if (targets.isEmpty) throw StateError('NO_RECIPIENT');
    await live.heartbeat(targets.map((m) => m['user_id'] as String));
    if (!context.mounted) return;
    final available = targets
        .where((m) => live.online.contains(m['user_id']))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '对方未在线，请双方打开 App 后再试。',
              'Recipient is offline. Both parties must open the app.',
            ),
          ),
        ),
      );
      return;
    }
    String? target;
    if (available.length == 1) {
      target = available.single['user_id'] as String;
    } else {
      target = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(tr('选择一个在线接收人', 'Choose one online recipient')),
              ),
              for (final m in available)
                ListTile(
                  title: Text(m['nickname'] as String),
                  onTap: () => Navigator.pop(ctx, m['user_id']),
                ),
            ],
          ),
        ),
      );
    }
    if (target == null || !context.mounted) return;
    final selection = await FilePicker.platform.pickFiles(withData: false);
    if (selection == null || !context.mounted) return;
    final file = selection.files.single;
    if (file.path == null) throw StateError('FILE_PATH_UNAVAILABLE');
    final size = await File(file.path!).length();
    if (size < 1 || size > maxDirectFileBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('请选择 1 字节至 3000MB 的文件。', 'Choose a file up to 3000 MB.'),
            ),
          ),
        );
      }
      return;
    }
    final offer = <String, dynamic>{
      'id': const Uuid().v4(),
      'room_id': room,
      'receiver_id': target,
      'name': file.name,
      'size': size,
    };
    await live.call('offer', offer);
    if (!context.mounted) {
      await live.call('cancel', {'id': offer['id']});
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DirectTransferPage(
          app: app,
          live: live,
          offer: offer,
          sourcePath: file.path,
        ),
      ),
    );
  } catch (e) {
    debugPrint('P2P offer failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              e.toString().contains('PGRST202')
                  ? '请先执行 013 聊天在线与直传配置。'
                  : '无法发起直传，请检查网络、对方在线状态和聊天权限。',
              'Cannot start transfer. Check deployment, connection, recipient status and permissions.',
            ),
          ),
        ),
      );
    }
  }
}

class DirectTransferPage extends StatefulWidget {
  final AppController app;
  final ChatLive live;
  final Map<String, dynamic> offer;
  final String? sourcePath;
  const DirectTransferPage({
    super.key,
    required this.app,
    required this.live,
    required this.offer,
    this.sourcePath,
  });
  @override
  State<DirectTransferPage> createState() => _DirectTransferPageState();
}

class _DirectTransferPageState extends State<DirectTransferPage>
    with WidgetsBindingObserver {
  late final DirectTransfer transfer;
  bool recording = false;
  String tr(String a, String b) => widget.app.text(a, b);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    transfer = DirectTransfer(
      widget.live,
      widget.offer,
      sourcePath: widget.sourcePath,
    )..addListener(changed);
    unawaited(transfer.start());
  }

  void changed() {
    if (mounted) setState(() {});
    if (transfer.savedPath != null && !recording) {
      recording = true;
      unawaited(recordReceived());
    }
  }

  Future<void> recordReceived() async {
    try {
      if (!await File(transfer.savedPath!).exists()) {
        recording = false;
        return;
      }
      final store = await ChatStore.open(widget.live.remote.userId);
      final key = 'received_files:${widget.offer['room_id']}';
      final previous = await store.read(key);
      await store.write(key, [
        ...previous.where((r) => r['id'] != widget.offer['id']),
        {
          'id': widget.offer['id'],
          'name': widget.offer['name'],
          'path': transfer.savedPath,
          'size': widget.offer['size'],
          'at': DateTime.now().toUtc().toIso8601String(),
        },
      ]);
    } catch (e) {
      recording = false;
      debugPrint('Record received file: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !transfer.ended) {
      unawaited(transfer.fail(StateError('APP_BACKGROUNDED')));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    transfer.removeListener(changed);
    unawaited(transfer.shutdown());
    super.dispose();
  }

  String get status => switch (transfer.state) {
    'waiting' => tr('等待对方确认接收', 'Waiting for recipient approval'),
    'connecting' => tr('正在建立点对点连接', 'Connecting peer to peer'),
    'transferring' => tr('正在传输', 'Transferring'),
    'verifying' => tr('正在校验文件完整性', 'Verifying file integrity'),
    'received' => tr('文件已保存，等待发送方确认', 'Saved; awaiting sender acknowledgement'),
    'complete' => tr('双方已确认传输完成', 'Transfer confirmed complete'),
    'cancelled' => tr('已取消', 'Cancelled'),
    _ => tr('传输未完成', 'Transfer did not complete'),
  };
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: transfer.ended,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('取消传输并返回？', 'Cancel transfer and go back?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('继续传输', 'Continue')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('取消传输', 'Cancel transfer')),
            ),
          ],
        ),
      );
      if (leave == true) {
        await transfer.cancel();
        if (context.mounted) Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(title: Text(tr('在线文件直传', 'Direct file transfer'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.swap_horiz, size: 56),
          const SizedBox(height: 16),
          Text(
            widget.offer['name'] as String,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          Text(status),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: transfer.bytes / transfer.size),
          if (transfer.state == 'transferring')
            Text(
              '${tr('点对点直传', 'Peer-to-peer')} · ${(transfer.bytesPerSecond / 1024).toStringAsFixed(0)} KB/s · ${transfer.remainingSeconds == null ? tr('估算中', 'Estimating') : tr('预计剩余 ${transfer.remainingSeconds} 秒', 'About ${transfer.remainingSeconds} seconds remaining')}',
            ),
          Text(
            '${(transfer.bytes / 1000000).toStringAsFixed(1)} / ${(transfer.size / 1000000).toStringAsFixed(1)} MB',
          ),
          const SizedBox(height: 20),
          Text(
            tr(
              '请双方保持 App 前台打开。文件分块直传，不经过云存储。视频和音频按原文件发送。',
              'Keep both apps in the foreground. Files, videos and audio are transferred directly in chunks.',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              '尚未配置 TURN 中继，部分移动网络或跨运营商网络可能无法连接。失败时可尝试让双方连接同一个 Wi-Fi。',
              'No TURN relay is configured. Some mobile or cross-carrier networks may fail; try the same Wi-Fi.',
            ),
          ),
          if (transfer.state == 'failed')
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                tr(
                  transfer.failure?.contains('APP_BACKGROUNDED') == true
                      ? 'App 已转入后台，传输中止，请重新发送。'
                      : '连接中断、对方拒绝、校验失败或网络不支持直连。未确认发送成功，请重新发送。',
                  'Transfer interrupted or could not be verified. It is not confirmed sent; retry with both apps open.',
                ),
              ),
            ),
          if (!transfer.ended)
            TextButton(
              onPressed: () => transfer.cancel(),
              child: Text(tr('取消传输', 'Cancel transfer')),
            ),
          if (transfer.savedPath != null) ...[
            const SizedBox(height: 16),
            SelectableText(tr('已保存到：', 'Saved to: ') + transfer.savedPath!),
            FilledButton.icon(
              onPressed: () async {
                if (isApk(widget.offer['name'] as String)) {
                  await showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      content: SizedBox(
                        width: 320,
                        child: ApkFileCard(
                          name: widget.offer['name'],
                          size: transfer.size,
                          guard: transfer.live.remote.checkUser,
                          load: (changed) async {
                            final path = await ApkFiles.stage(
                              transfer.live.remote.userId,
                              transfer.id,
                              widget.offer['name'],
                              transfer.savedPath!,
                            );
                            changed(1);
                            return path;
                          },
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  );
                  return;
                }
                final result = await OpenFilex.open(transfer.savedPath!);
                if (context.mounted && result.type != ResultType.done) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr(
                          '文件已保存，系统暂无可打开此文件的应用。',
                          'File saved; no compatible app is available.',
                        ),
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.folder_open),
              label: Text(tr('打开已接收文件', 'Open received file')),
            ),
          ],
        ],
      ),
    ),
  );
}

class TransferInbox extends StatefulWidget {
  final AppController app;
  final ChatLive live;
  const TransferInbox({super.key, required this.app, required this.live});
  @override
  State<TransferInbox> createState() => _TransferInboxState();
}

class _TransferInboxState extends State<TransferInbox> {
  final handled = <String>{};
  bool busy = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.live,
    builder: (context, _) {
      final offers = widget.live.offers
          .where((o) => !handled.contains(o['id']))
          .toList();
      if (offers.isEmpty) return const SizedBox.shrink();
      final offer = offers.first;
      String tr(String a, String b) => widget.app.text(a, b);
      return MaterialBanner(
        content: Text(
          '${offer['nickname']} ${tr('请求发送', 'wants to send')} ${offer['name']} (${((offer['size'] as num) / 1000000).toStringAsFixed(1)} MB)',
        ),
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await widget.live.call('cancel', {'id': offer['id']});
                      handled.add(offer['id'] as String);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(tr('操作失败，请重试', 'Please retry')),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(tr('拒绝', 'Decline')),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => handled.add(offer['id'] as String));
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => DirectTransferPage(
                          app: widget.app,
                          live: widget.live,
                          offer: offer,
                        ),
                      ),
                    );
                  },
            child: Text(tr('接收', 'Receive')),
          ),
        ],
      );
    },
  );
}
