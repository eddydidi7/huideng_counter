import 'package:flutter/material.dart';

import '../core/app_controller.dart';

/// The in-app destination for a stable `/u/{public_id}` HTTPS link.
/// It deliberately reads the public RPC only, so a link cannot expose private
/// notes, contact remarks, files, or the authenticated profile payload.
class PublicProfileLinkPage extends StatefulWidget {
  const PublicProfileLinkPage({super.key, required this.app, required this.publicId});
  final AppController app;
  final String publicId;

  @override
  State<PublicProfileLinkPage> createState() => _PublicProfileLinkPageState();
}

class _PublicProfileLinkPageState extends State<PublicProfileLinkPage> {
  Map<String, dynamic>? profile;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.app.cloud?.client?.rpc(
        'community_public_profile_v1',
        params: {'p_public_id': widget.publicId},
      );
      if (!mounted) return;
      if (result is! Map || result['profile'] == null) {
        setState(() => error = '此个人主页不存在或已不再公开');
        return;
      }
      setState(() => profile = Map<String, dynamic>.from(result['profile'] as Map));
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法加载个人主页');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return Scaffold(
      appBar: AppBar(title: const Text('个人主页')),
      body: p == null
          ? Center(child: Text(error ?? '正在加载…'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                CircleAvatar(
                  radius: 38,
                  backgroundImage: p['avatar_url'] is String && (p['avatar_url'] as String).isNotEmpty
                      ? NetworkImage(p['avatar_url'] as String)
                      : null,
                  child: p['avatar_url'] == null ? const Icon(Icons.person, size: 40) : null,
                ),
                const SizedBox(height: 12),
                Center(child: Text('${p['nickname'] ?? '学友'}', style: Theme.of(context).textTheme.headlineSmall)),
                if (p['personal_number'] != null) ...[
                  const SizedBox(height: 6),
                  Center(child: Text('个人号：${p['personal_number']}')),
                ],
                if ('${p['bio'] ?? ''}'.trim().isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('${p['bio']}'),
                ],
              ],
            ),
    );
  }
}
