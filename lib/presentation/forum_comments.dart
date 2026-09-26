import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../data/remote/forum_social.dart';
import 'forum_compose_page.dart' show forumFailure;
import 'forum_page.dart';

String socialFailure(AppController app, Object error) {
  if (forumSocialMissing(error)) {
    return '服务器尚未开通关注和评论新功能（需部署 202609250071 迁移）。';
  }
  if (error is PostgrestException) {
    switch (error.message) {
      case 'rate_limited':
        return '操作太频繁，请稍后再试。';
      case 'cannot_follow_self':
        return '不能关注自己。';
      case 'follow_limit':
        return '关注人数已达上限。';
      case 'replies_closed':
        return '该帖子已关闭评论。';
      case 'account_restricted':
        return '账号当前被限制发言。';
      case 'denied':
        return '只能删除自己的评论，或自己帖子下的评论。';
      case 'comment_unavailable':
        return '该评论已不存在。';
      case 'profile_required':
        return '请先在聊天中设置昵称后再评论。';
      case 'login_required':
        return '身份尚未就绪，请稍后重试。';
    }
  }
  return forumFailure(app, error);
}

/// Threaded comments: newest top-level comments first (paged by 20), each
/// with its first replies; more replies load on demand.
class ForumComments extends StatefulWidget {
  const ForumComments({
    super.key,
    required this.app,
    required this.social,
    required this.postId,
    this.slug,
    this.enabled = true,
    this.onCount,
  });
  final AppController app;
  final ForumSocial social;
  final String postId;
  final String? slug;
  final bool enabled;
  final ValueChanged<int>? onCount;
  @override
  State<ForumComments> createState() => ForumCommentsState();
}

class ForumCommentsState extends State<ForumComments> {
  List<Map<String, dynamic>> items = [];
  bool loading = false, more = false, sending = false;
  String? error;
  final busyIds = <String>{};
  static const page = 20;

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
      final result = await widget.social.comments(
        widget.postId,
        slug: widget.slug,
        after: append && items.isNotEmpty ? items.last : null,
        limit: page,
      );
      final rows = [
        for (final row in ForumSocial.items(result))
          {
            ...row,
            'children': [
              for (final c in row['children'] as List? ?? [])
                Map<String, dynamic>.from(c as Map),
            ],
          },
      ];
      if (!mounted) return;
      setState(() {
        items = append ? [...items, ...rows] : rows;
        more = rows.length == page;
      });
      if (result['reply_count'] is num) {
        widget.onCount?.call((result['reply_count'] as num).toInt());
      }
    } catch (e) {
      if (mounted) setState(() => error = '评论加载失败，点击重试');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> moreReplies(Map<String, dynamic> parent) async {
    final children = (parent['children'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    try {
      final result = await widget.social.comments(
        widget.postId,
        slug: widget.slug,
        parent: parent['id'] as String,
        after: children.isEmpty ? null : children.last,
      );
      if (!mounted) return;
      setState(
        () => parent['children'] = [...children, ...ForumSocial.items(result)],
      );
    } catch (_) {
      if (mounted) setState(() => error = '回复加载失败，请重试');
    }
  }

  /// Opens the input. [replyTo] is a comment (top-level or reply).
  Future<void> compose({Map<String, dynamic>? replyTo}) async {
    if (!widget.enabled || sending) return;
    final input = TextEditingController();
    final body = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 8,
          top: 12,
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + 12,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: input,
                autofocus: true,
                minLines: 1,
                maxLines: 5,
                maxLength: 5000,
                decoration: InputDecoration(
                  hintText: replyTo == null
                      ? '说点什么…'
                      : '回复 @${replyTo['author_name']}',
                  counterText: '',
                ),
              ),
            ),
            IconButton(
              tooltip: '发送',
              onPressed: () => Navigator.pop(ctx, input.text.trim()),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (body == null || body.isEmpty || !mounted) return;
    setState(() => sending = true);
    try {
      final result = await widget.social.comment(
        widget.postId,
        body,
        slug: widget.slug,
        replyTo: replyTo?['id'] as String?,
      );
      if (result['reply_count'] is num) {
        widget.onCount?.call((result['reply_count'] as num).toInt());
      }
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(socialFailure(widget.app, e))),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> like(Map<String, dynamic> c) async {
    final id = c['id'] as String;
    if (!busyIds.add(id)) return;
    final enabled = c['liked'] != true;
    setState(() {
      c['liked'] = enabled;
      c['like_count'] = ((c['like_count'] as num? ?? 0) + (enabled ? 1 : -1))
          .clamp(0, 1 << 31);
    });
    try {
      final result = await widget.social.likeComment(
        id,
        enabled,
        slug: widget.slug,
      );
      if (mounted) setState(() => c['like_count'] = result['like_count']);
    } catch (e) {
      if (mounted) {
        setState(() {
          c['liked'] = !enabled;
          c['like_count'] =
              ((c['like_count'] as num? ?? 0) + (enabled ? -1 : 1)).clamp(
                0,
                1 << 31,
              );
        });
      }
    } finally {
      busyIds.remove(id);
    }
  }

  Future<void> delete(Map<String, dynamic> c) async {
    final own = c['user_id'] == widget.social.userId;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(own ? '删除这条评论？' : '删除这条不适当评论？'),
        content: const Text('删除后其他人将看不到这条评论内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final result = await widget.social.deleteComment(
        c['id'] as String,
        slug: widget.slug,
      );
      if (result['reply_count'] is num) {
        widget.onCount?.call((result['reply_count'] as num).toInt());
      }
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(socialFailure(widget.app, e))),
        );
      }
    }
  }

  String time(Object? value) {
    final at = DateTime.tryParse(value as String? ?? '')?.toLocal();
    if (at == null) return '';
    final age = DateTime.now().difference(at);
    if (age.inMinutes < 1) return '刚刚';
    if (age.inHours < 1) return '${age.inMinutes}分钟前';
    if (age.inDays < 1) return '${age.inHours}小时前';
    if (age.inDays < 7) return '${age.inDays}天前';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }

  Widget comment(Map<String, dynamic> c, {bool child = false}) {
    final deleted = c['deleted'] == true;
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('forum-comment-${c['id']}'),
      padding: EdgeInsets.only(left: child ? 44 : 0, top: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => openForumAuthor(context, widget.app, {
              'author_user_id': c['user_id'],
            }),
            child: forumAuthorAvatar(widget.app, {
              'author_user_id': c['user_id'],
            }, radius: child ? 12 : 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: deleted || !widget.enabled ? null : () => compose(replyTo: c),
              onLongPress: c['can_delete'] == true ? () => delete(c) : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c['author_name'] as String? ?? '',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  deleted
                      ? Text(
                          '该评论已删除',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.disabledColor,
                          ),
                        )
                      : Text.rich(
                          TextSpan(
                            children: [
                              if (child && c['reply_to_name'] != null)
                                TextSpan(
                                  text: '回复 @${c['reply_to_name']}：',
                                  style: TextStyle(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              TextSpan(text: c['body'] as String? ?? ''),
                            ],
                          ),
                          style: theme.textTheme.bodyLarge,
                        ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(time(c['created_at']), style: theme.textTheme.bodySmall),
                      if (!deleted && widget.enabled) ...[
                        const SizedBox(width: 12),
                        Text('回复', style: theme.textTheme.bodySmall),
                      ],
                      if (c['can_delete'] == true) ...[
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: () => delete(c),
                          child: Text('删除', style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!deleted)
            InkWell(
              onTap: () => like(c),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  children: [
                    Icon(
                      c['liked'] == true ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: c['liked'] == true ? Colors.redAccent : null,
                    ),
                    Text(
                      forumCount(c['like_count'] as num?),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (error != null)
        TextButton(onPressed: () => load(), child: Text(error!)),
      if (items.isEmpty && !loading && error == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(widget.enabled ? '还没有评论，来说两句吧' : '暂无评论'),
        ),
      for (final c in items) ...[
        comment(c),
        for (final r in (c['children'] as List).cast<Map<String, dynamic>>())
          comment(r, child: true),
        if ((c['child_count'] as num? ?? 0) >
            (c['children'] as List? ?? []).length)
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => moreReplies(c),
                child: Text(
                  '展开更多回复（${(c['child_count'] as num).toInt() - (c['children'] as List? ?? []).length}）',
                ),
              ),
            ),
          ),
      ],
      if (loading) const Center(child: CircularProgressIndicator()),
      if (more && !loading)
        TextButton(
          onPressed: () => load(append: true),
          child: const Text('加载更多评论'),
        ),
    ],
  );
}
