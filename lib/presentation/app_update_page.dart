import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/app_controller.dart';
import '../services/apk_files.dart';
import '../services/app_release.dart';
import '../services/generic_download.dart';

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
      final platform = currentReleasePlatform();
      if (platform == null) throw StateError('当前平台暂不支持应用内更新');
      final installed = await InstalledApp.current();
      final client = widget.app.cloud?.client;
      if (client == null) throw StateError('暂时无法连接版本服务，请稍后重试');
      final next = await AppRelease.forPlatform(client, platform);
      if (!mounted) return;
      setState(() {
        current = installed.versionName;
        currentCode = installed.versionCode;
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
      void onProgress(double p) {
        if (mounted) setState(() => progress = p);
        debugPrint('[UPDATE_DOWNLOAD] download=${(p * 100).toStringAsFixed(0)}%');
      }

      if (Platform.isAndroid) {
        final path = await ApkFiles.download(
          owner: 'app-update',
          id: '${target.code}:${target.hash}',
          name: 'huideng-${target.name}.apk',
          size: target.size,
          checksum: target.hash,
          url: () async => target.url,
          guard: () {},
          progress: onProgress,
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
      } else {
        // Windows: no silent self-update. Download (size + sha256 verified
        // against the published release), then hand off to the installer's
        // own UI, same as a manually downloaded file.
        final dir = await getApplicationSupportDirectory();
        final ext = Uri.parse(target.url).path.split('.').last;
        final path = await downloadFile(
          url: target.url,
          targetPath: p.join(dir.path, 'app_update', 'huideng-${target.name}.$ext'),
          size: target.size,
          sha256Hex: target.hash,
          maxBytes: 524288000,
          onProgress: onProgress,
        );
        if (!mounted) return;
        setState(() => status = '下载完成，正在打开安装程序…');
        final result = await OpenFilex.open(path);
        if (result.type != ResultType.done) {
          throw StateError('无法自动打开安装程序，请在“$path”手动运行。');
        }
        if (mounted) setState(() => status = '请在安装程序中完成更新');
      }
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
          Text(Platform.isAndroid
              ? '更新保留现有数据。若系统要求，请允许来自此来源的应用；返回后由你确认安装。'
              : '更新保留现有数据。下载完成后会自动打开安装程序，请按提示完成安装。'),
        ],
      ),
    ),
  );
}
