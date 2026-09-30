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
import '../services/resumable_transfer.dart';
import '../services/transfer_activity.dart';

Future<List<Map<String, dynamic>>> pendingDirectFiles(ChatLive live) async =>
    (await ChatStore.open(live.remote.userId)).read('pending_direct_files');

final _pendingDirectChanges = ValueNotifier<int>(0);

Future<void> rememberDirectFile(
  ChatLive live,
  Map<String, dynamic> offer, {
  bool remove = false,
}) async {
  final store = await ChatStore.open(live.remote.userId);
  final rows = await store.read('pending_direct_files');
  rows.removeWhere((r) => r['id'] == offer['id']);
  if (!remove) rows.add(offer);
  await store.write('pending_direct_files', rows);
  _pendingDirectChanges.value++;
}

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
    String reference, name;
    int size;
    if (Platform.isAndroid) {
      final selected = await AndroidDocumentSource.pick();
      if (selected == null) return;
      reference = selected['reference'] as String;
      name = selected['name'] as String;
      size = selected['size'] as int;
    } else {
      final selection = await FilePicker.platform.pickFiles(withData: false);
      if (selection == null) return;
      final file = selection.files.single;
      if (file.path == null) throw StateError('FILE_PATH_UNAVAILABLE');
      reference = file.path!;
      name = file.name;
      size = await File(reference).length();
    }
    if (!context.mounted) return;
    if (size < 1 || size > maxDirectFileBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('请选择不超过 5GB 的文件或视频。', 'Choose a file or video up to 5 GB.'),
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
      'name': name,
      'size': size,
      '_device_id': live.deviceId,
      '_source': reference,
    };
    await live.transferCall('offer', {
      'id': offer['id'],
      'room_id': room,
      'receiver_id': target,
      'name': name,
      'size': size,
    });
    await rememberDirectFile(live, offer);
    if (!context.mounted) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DirectTransferPage(
          app: app,
          live: live,
          offer: offer,
          sourcePath: reference,
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
                  ? '请先部署 074 聊天文件续传配置。'
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
  bool recording = false, cleared = false;
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
    TransferActivity.forUser(widget.live.remote.userId).update(
      id: 'chat:${widget.offer['id']}',
      name: '${widget.offer['name']}',
      state: transfer.state,
      bytes: transfer.bytes,
      size: transfer.size,
      savedPath: transfer.savedPath,
    );
    if (!cleared &&
        (transfer.state == 'complete' || transfer.state == 'cancelled')) {
      cleared = true;
      unawaited(
        rememberDirectFile(
          widget.live,
          widget.offer,
          remove: true,
        ).catchError((Object e) => debugPrint('Clear direct transfer: $e')),
      );
    }
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
  Widget build(BuildContext context) => Scaffold(
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
                    ? 'App 已转入后台，已保留进度。请发送方继续传输，接收方再次确认。'
                    : '传输中断，已保留进度。请发送方继续传输，接收方再次确认；校验失败时需重新发送。',
                'Progress retained. The sender can resume and the recipient accepts again. A checksum failure requires a new transfer.',
              ),
            ),
          ),
        if (!transfer.ended)
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.pause),
            label: Text(tr('暂停并保留进度', 'Suspend and keep progress')),
          ),
        if (!transfer.ended)
          TextButton(
            onPressed: () => transfer.cancel(),
            child: Text(tr('取消传输', 'Cancel transfer')),
          ),
        if (transfer.state == 'failed' && widget.sourcePath != null)
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text(tr('继续传输', 'Resume transfer')),
            onPressed: () async {
              if (!context.mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DirectTransferPage(
                    app: widget.app,
                    live: widget.live,
                    offer: {...widget.offer, '_resume': true},
                    sourcePath: widget.sourcePath,
                  ),
                ),
              );
            },
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
  );
}

class TransferInbox extends StatefulWidget {
  final AppController app;
  final ChatLive live;
  final String? roomId;
  final int extraCount;
  final Widget? extraTasks;
  const TransferInbox({
    super.key,
    required this.app,
    required this.live,
    this.roomId,
    this.extraCount = 0,
    this.extraTasks,
  });
  @override
  State<TransferInbox> createState() => _TransferInboxState();
}

class _TransferInboxState extends State<TransferInbox> {
  final pending = ValueNotifier<List<Map<String, dynamic>>>([]);
  final busy = <String>{};
  late final activity = TransferActivity.forUser(widget.live.remote.userId);
  late final changes = Listenable.merge([widget.live, pending, activity]);
  @override
  void initState() {
    super.initState();
    _pendingDirectChanges.addListener(refresh);
    unawaited(activity.load());
    unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final rows = await pendingDirectFiles(widget.live);
      if (mounted) pending.value = rows;
    } catch (e) {
      debugPrint('Read pending direct transfers: $e');
    }
  }

  List<Map<String, dynamic>> get tasks {
    final rows = <String, Map<String, dynamic>>{};
    for (final row in [...pending.value, ...widget.live.offers]) {
      if (widget.roomId != null && row['room_id'] != widget.roomId) continue;
      final state = activity.records['chat:${row['id']}']?['state'];
      if (state == 'complete' || state == 'cancelled') continue;
      rows['${row['id']}'] = row;
    }
    return rows.values.toList();
  }

  Future<void> openTask(Map<String, dynamic> row) async {
    final source = row['_source'] as String?;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DirectTransferPage(
          app: widget.app,
          live: widget.live,
          offer: {...row, if (source != null) '_resume': true},
          sourcePath: source,
        ),
      ),
    );
    await refresh();
  }

  Future<void> cancel(Map<String, dynamic> row) async {
    final id = '${row['id']}';
    if (!busy.add(id)) return;
    pending.value = [...pending.value];
    try {
      await widget.live.transferCall('cancel', {
        'id': row['id'],
        if (row['_device_id'] != null) 'device_id': row['_device_id'],
      });
      await rememberDirectFile(widget.live, row, remove: true);
      activity.update(
        id: 'chat:$id',
        name: '${row['name']}',
        state: 'cancelled',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作失败，请检查网络后重试')));
      }
    } finally {
      busy.remove(id);
      if (mounted) pending.value = [...pending.value];
    }
  }

  Widget taskTile(Map<String, dynamic> row) {
    final record = activity.records['chat:${row['id']}'];
    final size = (row['size'] as num).toInt();
    final bytes = ((record?['bytes'] as num?)?.toInt() ?? 0).clamp(0, size);
    final state = record?['state'] as String? ?? 'waiting';
    final receiving = row['_source'] == null;
    final status = switch (state) {
      'transferring' => '正在传输',
      'connecting' => '连接中',
      'verifying' => '校验中',
      'failed' => '失败，可重试',
      'paused' => '已暂停',
      'interrupted' => '未完成',
      _ => '等待传输',
    };
    String mb(num value) => '${(value / 1048576).toStringAsFixed(1)} MB';
    return ListTile(
      title: Text(
        '${row['name']}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$status · ${mb(size)}'),
          LinearProgressIndicator(value: size > 0 ? bytes / size : 0),
          Text(
            '${size > 0 ? (bytes * 100 / size).floor() : 0}% · 剩余 ${mb(size - bytes)}',
          ),
          Wrap(
            children: [
              TextButton.icon(
                icon: Icon(receiving ? Icons.download : Icons.play_arrow),
                label: Text(
                  receiving
                      ? '接收'
                      : state == 'failed'
                      ? '重试'
                      : '继续',
                ),
                onPressed: busy.contains('${row['id']}')
                    ? null
                    : () => openTask(row),
              ),
              TextButton(
                onPressed: busy.contains('${row['id']}')
                    ? null
                    : () => cancel(row),
                child: Text(receiving ? '拒绝' : '取消'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: changes,
    builder: (context, _) => TransferTasksButton(
      count: tasks.length + widget.extraCount,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ListenableBuilder(
              listenable: changes,
              builder: (_, _) => ListView(
                children: [
                  const ListTile(title: Text('文件传输')),
                  if (tasks.isEmpty && widget.extraTasks == null)
                    const ListTile(title: Text('没有未完成的传输')),
                  for (final row in tasks) taskTile(row),
                  if (widget.extraTasks != null) widget.extraTasks!,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _pendingDirectChanges.removeListener(refresh);
    pending.dispose();
    super.dispose();
  }
}

/// Shared compact entry; an empty queue consumes no toolbar space.
class TransferTasksButton extends StatelessWidget {
  const TransferTasksButton({
    super.key,
    required this.count,
    required this.onPressed,
  });
  final int count;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => count == 0
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: '文件传输（$count）',
          onPressed: onPressed,
          icon: Badge(
            label: Text(count > 99 ? '99+' : '$count'),
            child: const Icon(Icons.swap_vert),
          ),
        );
}
