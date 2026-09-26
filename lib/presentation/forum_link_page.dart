import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/home_message_cache.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import 'forum_page.dart';

bool isForumShareSlug(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

/// In-app destination for a shared `/p/{slug}` HTTPS post link. The slug is
/// resolved through the public shared_page_v1 RPC, which only returns public
/// or link-only posts whose share link is still valid.
class ForumLinkPage extends StatefulWidget {
  const ForumLinkPage({super.key, required this.app, required this.slug});
  final AppController app;
  final String slug;
  @override
  State<ForumLinkPage> createState() => _ForumLinkPageState();
}

class _ForumLinkPageState extends State<ForumLinkPage> {
  String? postId, error;

  @override
  void initState() {
    super.initState();
    resolve();
  }

  Future<void> resolve() async {
    final client = widget.app.cloud?.client;
    if (client == null) {
      setState(() => error = '服务尚未就绪，请稍后重新打开链接。');
      return;
    }
    try {
      final page = await client
          .rpc('shared_page_v1', params: {'p_slug': widget.slug})
          .timeout(const Duration(seconds: 20));
      final id = (page as Map)['post']?['id'];
      if (id is! String) throw StateError('post_unavailable');
      if (mounted) setState(() => postId = id);
    } catch (_) {
      if (mounted) setState(() => error = '帖子不存在、已设为私密，或链接已失效。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.app.cloud?.client;
    if (postId != null && client != null) {
      return ForumDetailPage(
        app: widget.app,
        row: {'id': postId, 'share_slug': widget.slug},
        repository: ForumRepository(
          ForumRemote(client),
          HomeMessageCache(cacheKey: 'forum_feed'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('红书')),
      body: Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(error!, textAlign: TextAlign.center),
              ),
      ),
    );
  }
}
