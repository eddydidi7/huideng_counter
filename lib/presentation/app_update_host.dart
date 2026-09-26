import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

class _AppUpdateHostState extends State<AppUpdateHost> {
  static final Set<int> prompted = {};
  Timer? timer;
  bool checking = false, finished = false;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => check());
  }

  Future<void> check() async {
    final client = widget.app.cloud?.client;
    final nav = widget.app.navigatorKey.currentState;
    if (!Platform.isAndroid ||
        client == null ||
        nav == null ||
        checking ||
        finished) {
      return;
    }
    checking = true;
    try {
      final next = await AppRelease.latest(client);
      final info = await ApkFiles.channel.invokeMapMethod<String, dynamic>(
        'current',
      );
      finished = true;
      timer?.cancel();
      if (next == null ||
          next.code <= ((info?['versionCode'] as num?)?.toInt() ?? 0) ||
          !mounted) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('update_later_${next.code}') ?? 0;
      if (!next.force &&
          (prompted.contains(next.code) ||
              DateTime.now().millisecondsSinceEpoch - last <
                  const Duration(days: 1).inMilliseconds)) {
        return;
      }
      prompted.add(next.code);
      if (!mounted || !nav.mounted) return;
      final yes = await showDialog<bool>(
        context: nav.context,
        barrierDismissible: !next.force,
        builder: (ctx) => PopScope(
          canPop: !next.force,
          child: AlertDialog(
            title: Text('发现新版本 ${next.name}'),
            content: SingleChildScrollView(child: Text(next.notes)),
            actions: [
              if (!next.force)
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
        ),
      );
      if (yes == true && mounted) {
        await nav.push(
          MaterialPageRoute<void>(
            builder: (_) => AppUpdatePage(app: widget.app),
          ),
        );
      } else {
        await prefs.setInt(
          'update_later_${next.code}',
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (_) {
      // Offline checks must never block local use. Manual retry remains available.
      finished = true;
      timer?.cancel();
    } finally {
      checking = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
