import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../services/apk_files.dart';
import '../services/app_release.dart';
import 'app_update_page.dart';

class AppUpdateHost extends StatefulWidget {
  final AppController app;
  final Widget child;
  const AppUpdateHost({super.key, required this.app, required this.child});
  @override
  State<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends State<AppUpdateHost>
    with WidgetsBindingObserver {
  final prompted = <int>{};
  Timer? timer;
  bool checking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => check());
    timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  Future<void> check() async {
    final client = widget.app.cloud?.client;
    final nav = widget.app.navigatorKey.currentState;
    if (!Platform.isAndroid ||
        client == null ||
        nav == null ||
        checking ||
        !mounted) {
      return;
    }
    checking = true;
    try {
      final next = await AppRelease.latest(client);
      final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
        'current',
      );
      if (info?['versionCode'] is! num) return;
      final code = (info!['versionCode'] as num).toInt();
      try {
        await ApkFiles.cleanupUpdates(code);
      } catch (_) {
        /* Best-effort cache cleanup. */
      }
      if (next == null || !next.shouldPromptFor(code) || !mounted) {
        return;
      }
      final force = next.requiredFor(code);
      if (!force && !prompted.add(next.code)) return;
      if (!nav.mounted) return;
      if (force || next.autoDownload) {
        await nav.push(
          MaterialPageRoute<void>(
            builder: (_) => AppUpdatePage(
              app: widget.app,
              initialRelease: next,
              installedCode: code,
              autoStart: next.autoDownload,
            ),
          ),
        );
        return;
      }
      final yes = await showDialog<bool>(
        context: nav.context,
        builder: (ctx) => AlertDialog(
          title: Text('发现新版本 ${next.name}'),
          content: SingleChildScrollView(
            child: Text(
              '当前版本：${info['versionName']} ($code)\n最新版本：${next.name} (${next.code})\n发布时间：${next.publishedAt.toLocal()}\n${(next.size / 1048576).toStringAsFixed(1)} MB\n\n${next.notes}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后更新'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (yes == true && mounted && nav.mounted) {
        await nav.push(
          MaterialPageRoute<void>(
            builder: (_) => AppUpdatePage(
              app: widget.app,
              initialRelease: next,
              installedCode: code,
              downloadOnOpen: true,
            ),
          ),
        );
      }
    } catch (_) {
      // Retry transient startup failures; never turn a failed query into "latest".
    } finally {
      checking = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
