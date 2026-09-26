import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/remote/forum_social.dart';
import 'forum_comments.dart' show socialFailure;
import 'forum_page.dart' show forumAuthorAvatar;
import 'public_profile_page.dart';

/// Followers or following of [userId], newest first, 30 per page.
class FollowListPage extends StatefulWidget {
  const FollowListPage({
    super.key,
    required this.app,
    required this.userId,
    required this.followers,
    required this.title,
  });
  final AppController app;
  final String userId, title;
  final bool followers;
  @override
  State<FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends State<FollowListPage> {
  List<Map<String, dynamic>> people = [];
  bool loading = false, more = false;
  String? error;
  final busy = <String>{};
  ForumSocial get api => ForumSocial(widget.app.cloud!.client!);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool append = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rows = await api.people(
        widget.userId,
        followers: widget.followers,
        after: append && people.isNotEmpty ? people.last : null,
      );
      if (!mounted) return;
      setState(() {
        people = append ? [...people, ...rows] : rows;
        more = rows.length == 30;
      });
    } catch (e) {
      if (mounted) setState(() => error = socialFailure(widget.app, e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggle(Map<String, dynamic> person) async {
    final id = person['user_id'] as String;
    if (!busy.add(id)) return;
    setState(() {});
    try {
      final state = await api.follow(id, person['following'] != true);
      if (mounted) setState(() => person['following'] = state['following']);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(socialFailure(widget.app, e))),
        );
      }
    } finally {
      busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.app.cloud?.client?.auth.currentUser?.id;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (error != null)
              ListTile(title: Text(error!), onTap: () => load()),
            if (people.isEmpty && !loading && error == null)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  widget.followers ? '还没有粉丝' : '还没有关注任何人',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final p in people)
              ListTile(
                key: ValueKey('follow-person-${p['user_id']}'),
                leading: forumAuthorAvatar(widget.app, {
                  'author_user_id': p['user_id'],
                }, radius: 20),
                title: Text(p['nickname'] as String? ?? '学友'),
                subtitle: p['personal_number'] == null
                    ? null
                    : Text('个人号：${p['personal_number']}'),
                trailing: p['user_id'] == me
                    ? null
                    : p['following'] == true
                    ? OutlinedButton(
                        onPressed: busy.contains(p['user_id'])
                            ? null
                            : () => toggle(p),
                        child: const Text('已关注'),
                      )
                    : FilledButton(
                        onPressed: busy.contains(p['user_id'])
                            ? null
                            : () => toggle(p),
                        child: const Text('关注'),
                      ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PublicProfilePage(
                      app: widget.app,
                      userId: p['user_id'] as String,
                    ),
                  ),
                ),
              ),
            if (loading) const Center(child: CircularProgressIndicator()),
            if (more && !loading)
              TextButton(
                onPressed: () => load(append: true),
                child: const Text('加载更多'),
              ),
          ],
        ),
      ),
    );
  }
}
