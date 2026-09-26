import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/apk_files.dart';

class ApkFileCard extends StatefulWidget {
  const ApkFileCard({
    super.key,
    required this.name,
    required this.size,
    required this.load,
    required this.guard,
    this.localPath,
    this.createdAt,
    this.cached,
  });
  final Future<String?> Function()? cached;
  final String name;
  final int size;
  final String? localPath, createdAt;
  final Future<String> Function(void Function(double)) load;
  final void Function() guard;
  @override
  State<ApkFileCard> createState() => _ApkFileCardState();
}

class _ApkFileCardState extends State<ApkFileCard> {
  String? path, error, version;
  double progress = 0;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    path = widget.localPath;
    widget.cached
        ?.call()
        .then((p) {
          if (mounted && path == null) setState(() => path = p);
        })
        .catchError((Object _) {});
  }

  Future<void> download() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      widget.guard();
      final p = await widget.load((v) {
        if (mounted) setState(() => progress = v);
      });
      widget.guard();
      if (!mounted) return;
      setState(() => path = p);
      if (Platform.isAndroid) {
        final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
          'inspect',
          p,
        );
        if (mounted) setState(() => version = info?['versionName']?.toString());
      }
    } catch (_) {
      if (mounted) setState(() => error = '下载或安装包检查失败，可重试。请检查网络、文件和存储大小限制。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    try {
      widget.guard();
      if (path == null || !await File(path!).exists()) {
        await download();
        return;
      }
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('安装 Android 应用'),
          content: const Text('安装应用前，请确认文件来源可信。\n如系统要求，请允许来自此来源的应用；返回后继续系统安装。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续安装'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      widget.guard();
      await ApkFiles.channel.invokeMethod('install', path);
    } catch (_) {
      if (mounted) setState(() => error = '无法启动安装，请检查系统授权或安装包是否完整。');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.android, color: Colors.green),
          const SizedBox(width: 8),
          Flexible(child: Text(widget.name)),
        ],
      ),
      Text('Android安装包 · ${(widget.size / 1048576).toStringAsFixed(1)} MB'),
      if (widget.createdAt != null) Text(widget.createdAt!),
      if (version != null) Text('版本：$version'),
      if (busy) ...[
        LinearProgressIndicator(value: progress),
        Text('${(progress * 100).floor()}%'),
      ],
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Wrap(
        children: [
          TextButton(
            onPressed: busy
                ? null
                : path == null
                ? download
                : Platform.isAndroid
                ? install
                : null,
            child: Text(
              path == null
                  ? (error == null ? '下载' : '重试下载')
                  : Platform.isAndroid
                  ? '安装'
                  : '已保存',
            ),
          ),
          if (path != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        widget.guard();
                        if (Platform.isAndroid || Platform.isIOS) {
                          await ApkFiles.channel.invokeMethod('share', path);
                        } else {
                          final folder = await FilePicker.platform
                              .getDirectoryPath();
                          if (folder != null) {
                            final target = File(
                              '$folder/${safeApkName(widget.name)}',
                            );
                            if (await target.exists()) {
                              throw StateError('文件已存在');
                            }
                            await File(path!).copy(target.path);
                          }
                        }
                      } catch (_) {
                        if (mounted) setState(() => error = '分享失败，文件仍保存在本地');
                      }
                    },
              child: const Text('保存 / 转发'),
            ),
        ],
      ),
    ],
  );
}
