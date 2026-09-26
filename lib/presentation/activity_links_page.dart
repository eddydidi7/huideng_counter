import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';

/// Server-configured registration and activity links. URLs deliberately never
/// live in the APK, so an operator can update an event without a new release.
class ActivityLinksPage extends StatefulWidget {
  const ActivityLinksPage({super.key, required this.app});
  final AppController app;
  @override
  State<ActivityLinksPage> createState() => _ActivityLinksPageState();
}

class _ActivityLinksPageState extends State<ActivityLinksPage> {
  List<Map<String, dynamic>> rows = const [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.app.cloud!.client!
          .from('activity_links')
          .select()
          .eq('visible', true)
          .order('sort_order');
      if (mounted) {
        setState(() {
          rows = List<Map<String, dynamic>>.from(result);
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '报名项目暂时无法加载，请稍后重试。');
    }
  }

  Future<void> open(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https') return;
    var ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!ok) ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('网页无法打开，请稍后重试或使用浏览器打开。')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('共修报名')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (error != null)
            ListTile(
              title: Text(error!),
              trailing: const Icon(Icons.refresh),
              onTap: load,
            ),
          for (final row in rows)
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_available_outlined),
                title: Text('${row['title'] ?? ''}'),
                subtitle: Text('${row['summary'] ?? ''}'),
                trailing: Chip(label: Text(_status(row['status']))),
                onTap: row['status'] == 'ended'
                    ? null
                    : () => open('${row['link_url'] ?? ''}'),
              ),
            ),
          if (rows.isEmpty && error == null)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: Text('暂时没有报名项目')),
            ),
        ],
      ),
    ),
  );
  String _status(Object? s) => switch ('$s') {
    'upcoming' => '即将开始',
    'ended' => '已结束',
    _ => '报名中',
  };
}
