import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../core/app_controller.dart';
import '../services/assistant_session.dart';
import '../services/broadcast_inbox.dart';
import '../services/resumable_transfer.dart';
import '../data/remote/chat_live.dart';
import 'direct_transfer_page.dart';
import 'file_assistant_avatar.dart';
import '../services/transfer_activity.dart';

String fileSizeText(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0
      ? 0
      : value >= 100
      ? 0
      : 1)} ${units[unit]}';
}

String durationText(int? seconds) {
  if (seconds == null) return '估算中';
  if (seconds < 60) return '$seconds 秒';
  if (seconds < 3600) return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  return '${seconds ~/ 3600} 小时 ${(seconds % 3600) ~/ 60} 分';
}

class FileAssistantPage extends StatefulWidget {
  const FileAssistantPage({super.key, required this.app, this.live});
  final AppController app;
  final ChatLive? live;
  @override
  State<FileAssistantPage> createState() => _FileAssistantPageState();
}

class _FileAssistantPageState extends State<FileAssistantPage> {
  final manager = AssistantManager.instance;
  final inbox = BroadcastInbox.instance;
  List<Map<String, dynamic>> unfinished = [];
  final downloadProgress = <String, double>{};
  final downloading = <String>{};
  bool starting = true;
  bool draggingFiles = false;
  TransferActivity? activity;
  final taskChanges = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    manager.addListener(changed);
    inbox.addListener(changed);
    final user = widget.app.cloud?.client?.auth.currentUser?.id;
    if (user != null) {
      activity = TransferActivity.forUser(user)..addListener(changed);
      unawaited(activity!.load());
    }
    unawaited(load());
  }

  Future<void> load() async {
    final client = widget.app.cloud?.client;
    if (client != null) {
      await manager.ensure(client);
      unawaited(inbox.ensure(client));
    }
    final rows = await manager.resumable();
    if (mounted) setState(() => (unfinished = rows, starting = false));
    // Opening this page is the "seen" moment (spec: 进入文件传输助手可以看到).
    // Done after the frame, never inside build/broadcastTile, so it can't
    // trigger a notifyListeners() while a widget tree is being built.
    for (final item in inbox.items) {
      if (item['read_at'] == null) unawaited(inbox.markRead(item['broadcast_id'] as String));
    }
    if (mounted) taskChanges.value++;
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(changed);
    inbox.removeListener(changed);
    activity?.removeListener(changed);
    taskChanges.dispose();
    super.dispose();
  }

  Future<void> downloadBroadcast(Map<String, dynamic> item) async {
    final id = item['broadcast_id'] as String;
    if (downloading.contains(id)) return;
    setState(() {
      downloading.add(id);
      downloadProgress[id] = 0;
    });
    try {
      final path = await inbox.download(item, onProgress: (p) {
        if (mounted) setState(() => downloadProgress[id] = p);
      });
      if (mounted) await OpenFilex.open(path);
    } catch (e) {
      if (mounted) toast('下载失败：${e.toString().replaceAll('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => downloading.remove(id));
    }
  }

  Widget broadcastTile(Map<String, dynamic> item) {
    final id = item['broadcast_id'] as String;
    final isDownloading = downloading.contains(id);
    final progress = downloadProgress[id];
    final downloaded = item['downloaded_at'] != null;
    final unread = item['read_at'] == null;
    return Card(
      key: ValueKey('broadcast-$id'),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: unread ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: const Icon(Icons.campaign_outlined),
        title: Text('${item['title'] != '' ? item['title'] : item['file_name']}'),
        subtitle: Text(
          '${item['file_name']} · ${fileSizeText(item['file_size'] as num)}'
          '${(item['note'] as String? ?? '').isNotEmpty ? '\n${item['note']}' : ''}'
          '\n来自管理员${downloaded ? ' · 已下载' : ''}',
        ),
        isThreeLine: (item['note'] as String? ?? '').isNotEmpty,
        trailing: isDownloading
            ? SizedBox(
                width: 72,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    Text('${((progress ?? 0) * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              )
            : IconButton(
                icon: Icon(downloaded ? Icons.replay : Icons.download),
                onPressed: () => downloadBroadcast(item),
              ),
      ),
    );
  }

  void toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> sendTo(
    Map<String, dynamic> device, {
    List<String>? paths,
  }) async {
    try {
      final sources = <String>[];
      if (paths != null) {
        sources.addAll(paths);
      } else if (Platform.isAndroid) {
        // Read in place through the system picker: no 5 GB cache copy.
        final picked = await AndroidDocumentSource.pick();
        if (picked == null) return;
        await manager.send(
          receiverDevice: device['device_id'] as String,
          reference: picked['reference'] as String,
          name: picked['name'] as String,
          size: picked['size'] as int,
        );
        return;
      } else {
        final result = await FilePicker.platform.pickFiles(
          withData: false,
          allowMultiple: true,
        );
        if (result == null) return;
        sources.addAll(
          result.files.map((file) => file.path).whereType<String>(),
        );
      }
      var queued = 0;
      for (final source in sources) {
        final file = File(source);
        if (!await file.exists()) continue;
        final size = await file.length();
        if (size < 1) continue;
        if (size > assistantMaxFileBytes) {
          toast('已跳过 ${file.path.split(RegExp(r'[/\\]')).last}：单个文件超过 1 TB');
          continue;
        }
        await manager.send(
          receiverDevice: device['device_id'] as String,
          reference: source,
          name: file.path.split(RegExp(r'[/\\]')).last,
          size: size,
        );
        queued++;
      }
      if (queued > 0 && mounted) {
        toast(queued == 1 ? '已加入直传队列' : '已将 $queued 个文件加入直传队列');
      } else if (mounted) {
        toast('没有可发送的普通文件');
      }
    } catch (e) {
      toast(
        e.toString().contains('PEER_OFFLINE')
            ? '对方设备不在线：请在该设备打开文殊计算器 → 聊天 → 文件传输助手'
            : '无法发起传输：${e.toString().replaceAll('Exception: ', '')}',
      );
    }
  }

  Future<void> sendDroppedFiles(List<DropItem> files) async {
    if (files.isEmpty) return;
    final targets = manager.devices
        .where((d) => d['self'] != true && d['online'] == true)
        .toList();
    if (targets.isEmpty) {
      toast('没有在线的其他设备。请先在接收设备打开文件传输助手。');
      return;
    }
    final device = targets.length == 1
        ? targets.single
        : await showModalBottomSheet<Map<String, dynamic>>(
            context: context,
            builder: (ctx) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('选择接收设备')),
                  for (final target in targets)
                    ListTile(
                      leading: const Icon(Icons.computer),
                      title: Text('${target['name'] ?? '未命名设备'}'),
                      onTap: () => Navigator.pop(ctx, target),
                    ),
                ],
              ),
            ),
          );
    if (device == null || !mounted) return;
    await sendTo(device, paths: files.map((file) => file.path).toList());
  }

  Widget deviceTile(Map<String, dynamic> d) {
    final self = d['self'] == true, online = d['online'] == true;
    return ListTile(
      key: ValueKey('assistant-device-${d['device_id']}'),
      dense: true,
      leading: Icon(switch (d['platform']) {
        'windows' || 'macos' || 'linux' => Icons.computer,
        _ => Icons.smartphone,
      }, color: online ? Colors.green : null),
      title: Text(
        '${d['name'] == '' ? '未命名设备' : d['name']}${self ? '（本机）' : ''}',
      ),
      subtitle: Text(
        self
            ? '当前设备'
            : online
            ? '在线 · 点此选择文件发送'
            : '离线',
      ),
      trailing: !self && online ? const Icon(Icons.send_outlined) : null,
      onTap: !self && online ? () => sendTo(d) : null,
    );
  }

  Widget transferCard(AssistantSession s) {
    final percent = s.size == 0 ? 0.0 : s.bytes / s.size;
    final status = switch (s.state) {
      'waiting' => '等待对方设备接收',
      'connecting' => '正在建立直连…',
      'transferring' => s.sending ? '正在发送' : '正在接收',
      'paused' => '已暂停',
      'interrupted' => '连接中断，等待自动重连（已完成部分会保留）',
      'unreachable' =>
        '无法建立直连：可能是 NAT 或防火墙限制。请让两台设备连接同一 Wi-Fi 后点“重试”。不会改用云端上传。',
      'verifying' => '正在校验文件完整性…',
      'complete' => s.sending ? '发送完成，对方已校验' : '接收完成，已校验一致',
      'cancelled' => '已取消',
      _ => '传输出错，已完成的部分会保留，可重新发送',
    };
    return Card(
      key: ValueKey('assistant-transfer-${s.id}'),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(s.sending ? Icons.upload : Icons.download, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (s.route != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      s.route == 'lan' ? '局域网直传' : 'P2P 直连',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: percent.clamp(0, 1)),
            const SizedBox(height: 4),
            Text(
              '${fileSizeText(s.bytes)} / ${fileSizeText(s.size)} · ${(percent * 100).toStringAsFixed(1)}%'
              '${s.state == 'transferring' ? ' · ${fileSizeText(s.speed)}/s · 剩余 ${durationText(s.remainingSeconds)}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(status, style: Theme.of(context).textTheme.bodySmall),
            Text(
              '剩余 ${fileSizeText((s.size - s.bytes).clamp(0, s.size))}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (s.state == 'failed')
                  TextButton(
                    onPressed: () => manager.resume(s.record),
                    child: const Text('重试'),
                  ),
                if (s.state == 'unreachable')
                  TextButton(onPressed: s.retry, child: const Text('重试')),
                if (!s.ended && s.state != 'waiting' && s.state != 'verifying')
                  TextButton(
                    onPressed: () => s.setPaused(!s.paused),
                    child: Text(s.paused ? '继续' : '暂停'),
                  ),
                if (!s.ended)
                  TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('取消传输？'),
                          content: Text(
                            s.sending ? '对方已接收的部分会被删除。' : '已接收的部分会被删除，需要重新发送。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('继续传输'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('取消传输'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await s.cancel();
                    },
                    child: const Text('取消'),
                  ),
                if (s.savedPath != null)
                  TextButton(
                    onPressed: () => OpenFilex.open(s.savedPath!),
                    child: const Text('打开'),
                  ),
              ],
            ),
            if (s.savedPath != null)
              SelectableText(
                '保存位置：${s.savedPath}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget taskPanel() => ListenableBuilder(
    listenable: Listenable.merge([manager, inbox, ?activity, taskChanges]),
    builder: (_, _) {
      final sessions = manager.sessions.values.toList().reversed.toList();
      return Column(
        children: [
          if (!inbox.available)
            const ListTile(
              title: Text('服务器尚未开通后台群发'),
              subtitle: Text('需要部署 202609290076 迁移后才能使用。'),
            ),
          for (final item in inbox.items) broadcastTile(item),
          for (final offer in manager.offers)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.download),
                title: Text('${offer['name']}'),
                subtitle: Text(
                  '${fileSizeText(offer['size'] as num)} · 来自 '
                  '${manager.devices.where((d) => d['device_id'] == offer['sender_device']).map((d) => d['name']).firstOrNull ?? '我的其他设备'}',
                ),
                trailing: Wrap(
                  children: [
                    TextButton(
                      onPressed: () => manager.decline(offer),
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () => manager.accept(offer),
                      child: const Text('接收'),
                    ),
                  ],
                ),
              ),
            ),
          for (final s in sessions) transferCard(s),
          for (final record
              in activity?.sortedRecords ?? <Map<String, dynamic>>[])
            if (record['state'] == 'complete' &&
                !sessions.any((s) => 'device:${s.id}' == record['id']))
              ListTile(
                leading: const Icon(Icons.task_alt, color: Colors.green),
                title: Text(
                  '${record['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('已完成'),
                trailing: record['path'] == null
                    ? null
                    : IconButton(
                        tooltip: '打开',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () =>
                            OpenFilex.open(record['path'] as String),
                      ),
              ),
          for (final r in unfinished.where(
            (r) => !manager.sessions.containsKey(r['id']),
          ))
            ListTile(
              dense: true,
              leading: const Icon(Icons.restart_alt),
              title: Text('${r['name']}'),
              subtitle: Text(
                '未完成的${r['role'] == 'send' ? '发送' : '接收'} · ${fileSizeText(r['size'] as num)} · 可从中断处继续',
              ),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: () async {
                      await manager.forget(r);
                      await load();
                    },
                    child: const Text('放弃'),
                  ),
                  FilledButton(
                    onPressed: () {
                      manager.resume(r);
                      setState(() {});
                    },
                    child: const Text('继续'),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );

  int get taskCount {
    final ids = <String>{
      for (final offer in manager.offers) '${offer['id']}',
      for (final session in manager.sessions.values)
        if (!['complete', 'cancelled'].contains(session.state)) session.id,
      for (final row in unfinished)
        if (!manager.sessions.containsKey(row['id'])) '${row['id']}',
    };
    return ids.length + inbox.unreadCount;
  }

  @override
  Widget build(BuildContext context) {
    final others = manager.devices.where((d) => d['self'] != true).toList();
    final content = RefreshIndicator(
      onRefresh: load,
      child: ListView(
        children: [
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            const ListTile(
              leading: Icon(Icons.file_upload_outlined),
              title: Text('将文件拖到此页面即可直传'),
              subtitle: Text('可一次拖入多个文件；文件本体仍只走 P2P。'),
            ),
          if (!manager.available)
            const ListTile(
              title: Text('服务器尚未开通文件传输助手'),
              subtitle: Text('需要部署 202609250073 迁移后才能使用。'),
            ),
          const ListTile(dense: true, title: Text('我的设备（同一账号）')),
          if (starting)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            ),
          for (final d in manager.devices) deviceTile(d),
          if (!starting && others.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '还没有其他设备。请在电脑或另一部手机上用同一账号登录文殊计算器，打开“聊天 → 文件传输助手”，这里就会出现该设备。',
              ),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: Text(
              '• 文件从一台设备直接传到另一台，不上传云端、不占云存储；服务器只负责登录、发现设备和建立连接。\n'
              '• 同一 Wi-Fi 下自动走局域网直传；不同网络时尝试 P2P 直连，连不上会明确提示，不会改为云端上传。\n'
              '• 单个文件可达 5GB 以上；分块传输并逐块校验，断网后重连会从已完成的位置继续。\n'
              '• 传输时请保持两台设备都打开文殊计算器。',
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            FileAssistantAvatar(size: 28),
            SizedBox(width: 8),
            Flexible(child: Text('文件传输助手')),
          ],
        ),
        actions: [
          if (widget.live != null)
            TransferInbox(
              app: widget.app,
              live: widget.live!,
              extraCount: taskCount,
              extraTasks: taskPanel(),
            )
          else
            TransferTasksButton(
              count: taskCount,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * .7,
                    child: ListView(
                      children: [
                        const ListTile(title: Text('文件传输')),
                        taskPanel(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Platform.isWindows || Platform.isMacOS || Platform.isLinux
          ? DropTarget(
              onDragEntered: (_) => setState(() => draggingFiles = true),
              onDragExited: (_) => setState(() => draggingFiles = false),
              onDragDone: (detail) async {
                if (mounted) setState(() => draggingFiles = false);
                await sendDroppedFiles(detail.files);
              },
              child: Stack(
                children: [
                  content,
                  if (draggingFiles)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .16),
                          child: const Center(
                            child: Text(
                              '松开即可发送文件',
                              style: TextStyle(fontSize: 20),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          : content,
    );
  }
}
