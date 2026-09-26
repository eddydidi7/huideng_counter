import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../core/app_controller.dart';
import '../services/assistant_session.dart';
import '../services/resumable_transfer.dart';

String fileSizeText(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : value >= 100 ? 0 : 1)} ${units[unit]}';
}

String durationText(int? seconds) {
  if (seconds == null) return '估算中';
  if (seconds < 60) return '$seconds 秒';
  if (seconds < 3600) return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  return '${seconds ~/ 3600} 小时 ${(seconds % 3600) ~/ 60} 分';
}

class FileAssistantPage extends StatefulWidget {
  const FileAssistantPage({super.key, required this.app});
  final AppController app;
  @override
  State<FileAssistantPage> createState() => _FileAssistantPageState();
}

class _FileAssistantPageState extends State<FileAssistantPage> {
  final manager = AssistantManager.instance;
  List<Map<String, dynamic>> unfinished = [];
  bool starting = true;

  @override
  void initState() {
    super.initState();
    manager.addListener(changed);
    unawaited(load());
  }

  Future<void> load() async {
    final client = widget.app.cloud?.client;
    if (client != null) await manager.ensure(client);
    final rows = await manager.resumable();
    if (mounted) setState(() => (unfinished = rows, starting = false));
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    manager.removeListener(changed);
    super.dispose();
  }

  void toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> sendTo(Map<String, dynamic> device) async {
    try {
      String? reference, name;
      int? size;
      if (Platform.isAndroid) {
        // Read in place through the system picker: no 5 GB cache copy.
        final picked = await AndroidDocumentSource.pick();
        if (picked == null) return;
        reference = picked['reference'] as String;
        name = picked['name'] as String;
        size = picked['size'] as int;
      } else {
        final result = await FilePicker.platform.pickFiles(withData: false);
        final file = result?.files.single;
        if (file?.path == null) return;
        reference = file!.path!;
        name = file.name;
        size = await File(reference).length();
      }
      if (size < 1) return toast('无法读取文件大小，请换一个文件');
      if (size > assistantMaxFileBytes) return toast('单个文件超过 1 TB，暂不支持');
      await manager.send(receiverDevice: device['device_id'] as String, reference: reference, name: name, size: size);
    } catch (e) {
      toast(e.toString().contains('PEER_OFFLINE')
          ? '对方设备不在线：请在该设备打开文殊计算器 → 聊天 → 文件传输助手'
          : '无法发起传输：${e.toString().replaceAll('Exception: ', '')}');
    }
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
      title: Text('${d['name'] == '' ? '未命名设备' : d['name']}${self ? '（本机）' : ''}'),
      subtitle: Text(self ? '当前设备' : online ? '在线 · 点此选择文件发送' : '离线'),
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
      'unreachable' => '无法建立直连：可能是 NAT 或防火墙限制。请让两台设备连接同一 Wi-Fi 后点“重试”。不会改用云端上传。',
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
                Expanded(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall)),
                if (s.route != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(s.route == 'lan' ? '局域网直传' : 'P2P 直连', style: const TextStyle(fontSize: 11)),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
                          content: Text(s.sending ? '对方已接收的部分会被删除。' : '已接收的部分会被删除，需要重新发送。'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续传输')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('取消传输')),
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
              SelectableText('保存位置：${s.savedPath}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final others = manager.devices.where((d) => d['self'] != true).toList();
    final sessions = manager.sessions.values.toList().reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件传输助手'),
        actions: [IconButton(tooltip: '刷新', onPressed: load, icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          children: [
            if (!manager.available)
              const ListTile(
                title: Text('服务器尚未开通文件传输助手'),
                subtitle: Text('需要部署 202609250073 迁移后才能使用。'),
              ),
            for (final offer in manager.offers)
              Card(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.download),
                  title: Text('${offer['name']}'),
                  subtitle: Text('${fileSizeText(offer['size'] as num)} · 来自 '
                      '${manager.devices.where((d) => d['device_id'] == offer['sender_device']).map((d) => d['name']).firstOrNull ?? '我的其他设备'}'),
                  trailing: Wrap(
                    children: [
                      TextButton(onPressed: () => manager.decline(offer), child: const Text('拒绝')),
                      FilledButton(onPressed: () => manager.accept(offer), child: const Text('接收')),
                    ],
                  ),
                ),
              ),
            for (final s in sessions) transferCard(s),
            for (final r in unfinished.where((r) => !manager.sessions.containsKey(r['id'])))
              ListTile(
                dense: true,
                leading: const Icon(Icons.restart_alt),
                title: Text('${r['name']}'),
                subtitle: Text('未完成的${r['role'] == 'send' ? '发送' : '接收'} · ${fileSizeText(r['size'] as num)} · 可从中断处继续'),
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
            const ListTile(dense: true, title: Text('我的设备（同一账号）')),
            if (starting) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
            for (final d in manager.devices) deviceTile(d),
            if (!starting && others.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有其他设备。请在电脑或另一部手机上用同一账号登录文殊计算器，打开“聊天 → 文件传输助手”，这里就会出现该设备。'),
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
      ),
    );
  }
}
