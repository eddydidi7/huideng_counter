import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_controller.dart';
import '../services/apk_files.dart';
import '../services/app_release.dart';

class AppUpdatePage extends StatefulWidget {
  final AppController app;
  final AppRelease? initialRelease;
  final int installedCode;
  final bool autoStart;
  final bool downloadOnOpen;
  const AppUpdatePage({
    super.key,
    required this.app,
    this.initialRelease,
    this.installedCode = 0,
    this.autoStart = false,
    this.downloadOnOpen = false,
  });
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  AppRelease? release;
  String current = '—', status = '', error = '';
  String? readyPath;
  int currentCode = 0;
  bool busy = false, stopped = false, cancelled = false, wifiOnly = true;
  double progress = 0;
  http.Client? transfer;
  Timer? networkTimer;
  Timer? wifiWait;
  bool waitingWifi = false;
  bool get mandatory => release?.requiredFor(currentCode) == true;
  @override
  void initState() {
    super.initState();
    release = widget.initialRelease;
    currentCode = widget.installedCode;
    check(automatic: widget.autoStart, download: widget.downloadOnOpen);
  }

  Future<void> check({bool automatic = false, bool download = false}) async {
    if (busy) return;
    wifiWait?.cancel();
    waitingWifi = false;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (!Platform.isAndroid) throw StateError('当前平台不支持 Android APK 安装');
      final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (info?['versionCode'] is! num) throw StateError('无法读取当前 versionCode');
      currentCode = (info!['versionCode'] as num).toInt();
      current = '${info['versionName']}';
      final prefs = await SharedPreferences.getInstance();
      wifiOnly = prefs.getBool('update.wifi_only') ?? true;
      final client = widget.app.cloud?.client;
      if (client == null) throw StateError('暂时无法连接版本服务，请稍后重试');
      final next = await AppRelease.latest(client);
      if (!mounted) return;
      if (next?.hash != release?.hash) {
        readyPath = null;
        progress = 0;
      }
      setState(() {
        release = next?.enabled == false ? null : next;
        status = release == null
            ? '服务器暂无已发布更新'
            : release!.code > currentCode
            ? '发现新版本'
            : '当前已是最新版本';
      });
      try {
        await ApkFiles.cleanupUpdates(currentCode);
      } catch (_) {
        /* Cache cleanup must not block updates. */
      }
    } catch (e) {
      if (mounted) setState(() => error = '检查更新失败：${describe(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted &&
        error.isEmpty &&
        ((automatic && release?.autoDownload == true) || download) &&
        release != null &&
        release!.code > currentCode) {
      await update(automatic: !download);
    }
  }

  String describe(Object e) => e is StateError
      ? e.message.toString()
      : e is PlatformException
      ? e.message ?? 'Android 安装服务错误'
      : e is FormatException
      ? e.message
      : '网络请求未完成，请重试';

  Future<bool> onWifi() async {
    final network = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
      'network',
    );
    return network?['wifi'] == true && network?['metered'] == false;
  }

  Future<void> update({bool automatic = false}) async {
    final target = release;
    if (target == null || busy || target.code <= currentCode) return;
    if (automatic && !target.autoDownload) return;
    wifiWait?.cancel();
    waitingWifi = false;
    var openInstaller = false;
    setState(() {
      busy = true;
      error = '';
      stopped = false;
      cancelled = false;
    });
    try {
      var wifi = false;
      try {
        wifi = await onWifi();
      } catch (_) {
        /* Unknown networks are metered. */
      }
      if (!mounted) return;
      final cached = await ApkFiles.target(
        'app-update',
        '${target.code}:${target.hash}',
        'huideng-${target.name}.apk',
      );
      final complete = await ApkFiles.valid(cached, target.size, target.hash);
      if (!mounted) return;
      if (automatic && (wifiOnly || target.wifiOnly) && !wifi && !complete) {
        waitingWifi = true;
        setState(() => status = '等待 Wi-Fi，可手动立即更新');
        return;
      }
      if (!automatic && !wifi && !complete) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('使用当前网络下载？'),
            content: Text(
              '安装包 ${(target.size / 1048576).toStringAsFixed(1)} MB，可能消耗移动数据。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('继续下载'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      final client = http.Client();
      transfer = client;
      setState(() => status = '下载中');
      if (automatic && (wifiOnly || target.wifiOnly)) {
        networkTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
          try {
            if (!await onWifi() && mounted && transfer != null) pause();
          } catch (_) {
            if (mounted && transfer != null) pause();
          }
        });
      }
      final path = await ApkFiles.download(
        owner: 'app-update',
        id: '${target.code}:${target.hash}',
        name: 'huideng-${target.name}.apk',
        size: target.size,
        checksum: target.hash,
        url: () async => target.url,
        requireApk: true,
        transport: client,
        guard: () {
          if (!mounted || stopped) throw StateError('下载已暂停');
        },
        progress: (p) {
          if (mounted) setState(() => progress = p);
        },
      );
      transfer?.close();
      transfer = null;
      networkTimer?.cancel();
      if (!mounted || stopped) return;
      setState(() => status = '正在校验安装包版本与签名');
      await verify(target, path);
      if (!mounted) return;
      setState(() {
        readyPath = path;
        status = '新版本已经下载完成，立即安装';
      });
      openInstaller = !automatic;
    } catch (e) {
      if (mounted && !stopped) setState(() => error = describe(e));
    } finally {
      transfer?.close();
      transfer = null;
      networkTimer?.cancel();
      if (cancelled) {
        try {
          final file = await ApkFiles.target(
            'app-update',
            '${target.code}:${target.hash}',
            'huideng-${target.name}.apk',
          );
          final part = File('${file.path}.part');
          if (await part.exists()) await part.delete();
        } catch (_) {
          if (mounted) setState(() => error = '临时下载未能清理，请稍后重试');
        }
      }
      if (mounted) setState(() => busy = false);
      if (waitingWifi && mounted) {
        wifiWait = Timer.periodic(const Duration(seconds: 10), (_) async {
          if (!mounted ||
              busy ||
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed) {
            return;
          }
          try {
            if (await onWifi() && mounted && waitingWifi) {
              wifiWait?.cancel();
              await update(automatic: true);
            }
          } catch (_) {
            /* Keep waiting without using a metered network. */
          }
        });
      }
    }
    // Only a user-requested download opens system confirmation, in foreground.
    if (openInstaller &&
        mounted &&
        !stopped &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await install();
    }
  }

  Future<void> verify(AppRelease target, String path) async {
    if (!await ApkFiles.valid(File(path), target.size, target.hash)) {
      throw StateError('安装包校验失败，请重新下载。');
    }
    final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
      'verifyUpdate',
      path,
    );
    if (info?['versionCode'] != target.code ||
        info?['versionName'] != target.name) {
      throw StateError('安装包版本与发布信息不一致，已禁止安装');
    }
  }

  void pause({bool cancel = false}) {
    stopped = true;
    cancelled = cancel;
    transfer?.close();
    setState(() {
      status = cancel ? '下载已取消' : '已暂停，可继续下载';
      if (cancel) progress = 0;
    });
  }

  Future<void> install() async {
    if (busy || readyPath == null || release == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await verify(release!, readyPath!);
      final result = await ApkFiles.channel.invokeMethod('install', readyPath);
      if (mounted) {
        setState(
          () => status = result == 'permission_required'
              ? '请允许来自此来源的应用，返回后在系统界面确认安装'
              : '请在 Android 系统界面确认安装',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> discardPartial() async {
    final target = release;
    if (busy || target == null) return;
    wifiWait?.cancel();
    waitingWifi = false;
    setState(() => busy = true);
    try {
      final file = await ApkFiles.target(
        'app-update',
        '${target.code}:${target.hash}',
        'huideng-${target.name}.apk',
      );
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
      if (mounted) {
        setState(() {
          stopped = true;
          cancelled = true;
          progress = 0;
          status = '下载已取消';
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '临时下载未能清理，请稍后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    stopped = true;
    transfer?.close();
    networkTimer?.cancel();
    wifiWait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !mandatory,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('更新版本'),
        automaticallyImplyLeading: !mandatory,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('当前版本：$current ($currentCode)'),
          if (release != null) ...[
            Text('最新版本：${release!.name} (${release!.code})'),
            Text('发布时间：${release!.publishedAt.toLocal()}'),
            Text('${(release!.size / 1048576).toStringAsFixed(1)} MB'),
            Text(release!.notes),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('仅 Wi-Fi 自动下载'),
            value: wifiOnly || release?.wifiOnly == true,
            onChanged: busy || release?.wifiOnly == true
                ? null
                : (v) async {
                    setState(() => wifiOnly = v);
                    await (await SharedPreferences.getInstance()).setBool(
                      'update.wifi_only',
                      v,
                    );
                  },
          ),
          Text(status),
          if (busy)
            LinearProgressIndicator(value: status == '下载中' ? progress : null),
          if (release != null && progress > 0)
            Text(
              '${(progress * release!.size / 1048576).toStringAsFixed(1)} / ${(release!.size / 1048576).toStringAsFixed(1)} MB · ${(progress * 100).toStringAsFixed(0)}%',
            ),
          if (error.isNotEmpty)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            spacing: 12,
            children: [
              if (!mandatory)
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('稍后更新'),
                ),
              if (!busy && readyPath == null && (progress > 0 || waitingWifi))
                TextButton(
                  onPressed: discardPartial,
                  child: const Text('取消下载'),
                ),
              TextButton(
                onPressed: busy ? null : check,
                child: const Text('检查更新'),
              ),
              if (transfer != null && !stopped) ...[
                TextButton(onPressed: pause, child: const Text('暂停')),
                TextButton(
                  onPressed: () => pause(cancel: true),
                  child: const Text('取消下载'),
                ),
              ],
              if (release != null && release!.code > currentCode)
                FilledButton(
                  onPressed: busy
                      ? null
                      : readyPath != null
                      ? install
                      : update,
                  child: Text(
                    readyPath != null
                        ? '立即安装'
                        : stopped && !cancelled
                        ? '继续下载'
                        : error.isNotEmpty
                        ? '失败重试'
                        : '立即更新',
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
