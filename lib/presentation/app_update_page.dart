import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../services/apk_files.dart';
import '../services/app_release.dart';

class AppUpdatePage extends StatefulWidget {
  final AppController app;
  const AppUpdatePage({super.key, required this.app});
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  AppRelease? release;
  String current = '—', status = '', error = '';
  int currentCode = 0;
  bool busy = false;
  double progress = 0;
  @override
  void initState() {
    super.initState();
    check();
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (!Platform.isAndroid) throw StateError('当前平台不支持 Android APK 安装');
      final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
        'current',
      );
      final client = widget.app.cloud?.client;
      if (client == null) throw StateError('暂时无法连接版本服务，请稍后重试');
      final next = await AppRelease.latest(client);
      if (!mounted) return;
      setState(() {
        current = info?['versionName']?.toString() ?? '—';
        currentCode = (info?['versionCode'] as num?)?.toInt() ?? 0;
        release = next;
        status = next == null
            ? '暂未发布正式更新'
            : next.code > currentCode
            ? '发现新版本'
            : '当前已是最新版本';
      });
    } catch (e) {
      if (mounted) setState(() => error = '检查更新失败，请联网重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> update() async {
    final target = release;
    if (target == null || busy) return;
    setState(() {
      busy = true;
      error = '';
      status = '下载中';
    });
    try {
      final path = await ApkFiles.download(
        owner: 'app-update',
        id: '${target.code}:${target.hash}',
        name: 'huideng-${target.name}.apk',
        size: target.size,
        checksum: target.hash,
        url: () async => target.url,
        guard: () {},
        progress: (p) {
          if (mounted) setState(() => progress = p);
        },
      );
      // Validate actual package, certificate and version, not just manifest text.
      final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
        'verifyUpdate',
        path,
      );
      if (info?['versionCode'] != target.code ||
          info?['versionName'] != target.name) {
        throw StateError('安装包版本与发布信息不一致，已禁止安装');
      }
      if (!mounted) return;
      setState(() => status = '校验通过，请在系统界面确认安装');
      await ApkFiles.channel.invokeMethod('install', path);
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              '更新未完成，可重试。${e is StateError ? e.message : '请检查网络；安装包须与当前应用签名一致。'}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !(release?.force == true && release!.code > currentCode),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('更新版本'),
        automaticallyImplyLeading:
            !(release?.force == true && release!.code > currentCode),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('当前版本：$current'),
          if (release != null) ...[
            Text('最新版本：${release!.name}'),
            Text('${(release!.size / 1048576).toStringAsFixed(1)} MB'),
            const SizedBox(height: 12),
            Text(release!.notes),
          ],
          const SizedBox(height: 12),
          Text(status),
          if (busy) ...[
            LinearProgressIndicator(value: status == '下载中' ? progress : null),
            if (status == '下载中')
              Text('${(progress * 100).toStringAsFixed(0)}%'),
          ],
          if (error.isNotEmpty)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            spacing: 12,
            children: [
              TextButton(
                onPressed: busy ? null : check,
                child: const Text('检查更新'),
              ),
              if (release != null && release!.code > currentCode)
                FilledButton(
                  onPressed: busy ? null : update,
                  child: Text(error.isEmpty ? '立即更新' : '重试'),
                ),
            ],
          ),
          const Text('更新保留现有数据。若系统要求，请允许来自此来源的应用；返回后由你确认安装。'),
        ],
      ),
    ),
  );
}
