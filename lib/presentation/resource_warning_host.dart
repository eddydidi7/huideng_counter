import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_controller.dart';

/// Polls only this account's warnings; never reads other users or private content.
class ResourceWarningHost extends StatefulWidget {
  const ResourceWarningHost({
    super.key,
    required this.app,
    required this.child,
  });
  final AppController app;
  final Widget child;
  @override
  State<ResourceWarningHost> createState() => _ResourceWarningHostState();
}

class _ResourceWarningHostState extends State<ResourceWarningHost>
    with WidgetsBindingObserver {
  Timer? timer;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.app.addListener(check);
    timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
    WidgetsBinding.instance.addPostFrameCallback((_) => check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.app.removeListener(check);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> check() async {
    if (busy) return;
    final client = widget.app.cloud?.client;
    final owner = client?.auth.currentUser?.id;
    if (client == null || owner == null) return;
    busy = true;
    try {
      final raw = await client
          .rpc('resource_my_warnings')
          .timeout(const Duration(seconds: 10));
      final prefs = await SharedPreferences.getInstance();
      final key = 'resource_warning_seen_$owner';
      final seen = prefs.getStringList(key) ?? [];
      final fresh = (raw as List)
          .where((w) => !seen.contains(w['id']))
          .toList();
      final ctx = widget.app.navigatorKey.currentContext;
      if (!mounted ||
          client.auth.currentUser?.id != owner ||
          ctx == null ||
          !ctx.mounted ||
          fresh.isEmpty) {
        return;
      }
      await showDialog<void>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: const Text('管理员提醒'),
          content: SingleChildScrollView(
            child: Text(fresh.map((w) => w['message']).join('\n\n')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      if (mounted && client.auth.currentUser?.id == owner) {
        await prefs.setStringList(
          key,
          {...seen, ...fresh.map((w) => w['id'] as String)}.toList(),
        );
      }
    } catch (_) {
      /* Offline use and earlier servers must remain usable. */
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
