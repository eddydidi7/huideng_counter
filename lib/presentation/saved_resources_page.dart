import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../core/app_controller.dart';
import '../services/attachment_service.dart';
import 'cloud_drive_page.dart';
import 'settings_page.dart';

class SavedResourcesPage extends StatefulWidget {
  const SavedResourcesPage({super.key, required this.app, this.userId});
  final AppController app;
  final String? userId;
  @override
  State<SavedResourcesPage> createState() => _SavedResourcesPageState();
}

class _SavedResourcesPageState extends State<SavedResourcesPage> {
  late final api = AttachmentService(widget.app.cloud!.client!);
  List rows = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = widget.userId == null
          ? await api.group('saved_list', {})
          : await widget.app.cloud!.client!.rpc(
              'community_collection_v1',
              params: {'p_user': widget.userId, 'p_kind': 'resources'},
            );
      if (mounted) {
        setState(() {
          rows = r as List;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          rows = [];
          error = '资料夹未公开或暂时无法加载';
        });
      }
    }
  }

  Future<void> open(Map r) async {
    try {
      if (r['kind'] == 'resource') {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CloudDrivePage(
              app: widget.app,
              settingsPage: SettingsPage(app: widget.app),
              initialResourceId: r['source_id'],
            ),
          ),
        );
      } else {
        final f = await api.group('file_get', {
          'group_id': r['metadata']['group_id'],
          'id': r['source_id'],
        });
        if (f == null) throw StateError('原文件已移除或您已没有访问权限');
        await OpenFilex.open(await api.download(Map<String, dynamic>.from(f)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('个人资料夹')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        children: [
          const ListTile(
            subtitle: Text('这里保存资料引用，不重复占用存储；打开时仍需拥有原文件访问权限。公开范围由个人主页开关控制。'),
          ),
          if (error != null) ListTile(title: Text(error!)),
          for (final r in rows)
            ListTile(
              title: Text(r['title']),
              subtitle: Text(r['kind'] == 'resource' ? '公共资料' : '群文件'),
              onTap: () => open(r),
            ),
        ],
      ),
    ),
  );
}
