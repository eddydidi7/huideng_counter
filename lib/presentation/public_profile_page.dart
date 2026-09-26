import 'dart:async';
import 'personal_library_page.dart';
import 'follow_list_page.dart';
import 'forum_comments.dart' show socialFailure;
import '../data/remote/forum_social.dart';
import 'forum_compose_page.dart';
import 'jieyuan_actions.dart';
import '../domain/post_display.dart';
import 'chat_avatar.dart';
import '../data/remote/chat_remote.dart';
import 'saved_resources_page.dart';
import 'group_practice_page.dart';
import 'group_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/app_controller.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import '../data/local/home_message_cache.dart';
import 'forum_page.dart';

class PublicProfilePage extends StatefulWidget {
  const PublicProfilePage({super.key, required this.app, required this.userId});
  final AppController app;
  final String userId;
  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  Map<String, dynamic>? data;
  String? error;
  String tab = 'all';
  String? publicId;
  bool get own =>
      widget.app.cloud?.client?.auth.currentUser?.id == widget.userId;
  @override
  void initState() {
    super.initState();
    load();
  }

  Map<String, dynamic>? follow;
  bool followBusy = false;

  /// Separate from the profile so an undeployed social migration never
  /// hides the rest of the page.
  Future<void> loadFollow() async {
    try {
      final state = await ForumSocial(
        widget.app.cloud!.client!,
      ).followState(widget.userId);
      if (mounted) setState(() => follow = state);
    } catch (_) {
      if (mounted) setState(() => follow = null);
    }
  }

  Future<void> toggleFollow() async {
    if (followBusy || follow == null) return;
    setState(() => followBusy = true);
    try {
      final state = await ForumSocial(
        widget.app.cloud!.client!,
      ).follow(widget.userId, follow!['following'] != true);
      if (mounted) setState(() => follow = state);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(socialFailure(widget.app, e))),
        );
      }
    } finally {
      if (mounted) setState(() => followBusy = false);
    }
  }

  Future<void> openPeople(bool followers) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => FollowListPage(
          app: widget.app,
          userId: widget.userId,
          followers: followers,
          title: followers
              ? (own ? '我的粉丝' : 'TA的粉丝')
              : (own ? '我的关注' : 'TA的关注'),
        ),
      ),
    );
    if (mounted) await loadFollow();
  }

  Future<void> load() async {
    unawaited(loadFollow());
    try {
      final result = await widget.app.cloud!.client!.rpc(
        'community_profile_v1',
        params: {'p_user': widget.userId},
      );
      final id = await widget.app.cloud!.client!.rpc(
        'community_profile_public_id_v1',
        params: {'p_user': widget.userId},
      );
      if (mounted) {
        setState(() {
          data = Map<String, dynamic>.from(result);
          publicId = id as String?;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法加载个人主页');
    }
  }

  Future<String?> publicUrl() async {
    if (publicId == null) return null;
    final rows = await widget.app.cloud!.client!
        .from('community_config')
        .select('public_base_url')
        .eq('id', true)
        .limit(1);
    final base = rows.isEmpty
        ? ''
        : '${rows.first['public_base_url'] ?? ''}'.replaceFirst(
            RegExp(r'/$'),
            '',
          );
    return Uri.tryParse('$base/u/$publicId')?.scheme == 'https'
        ? '$base/u/$publicId'
        : null;
  }

  Future<void> shareProfile({required bool copy}) async {
    try {
      final url = await publicUrl();
      if (url == null) throw StateError('PUBLIC_PROFILE_URL_NOT_CONFIGURED');
      if (copy) {
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('链接已复制')));
        }
      } else {
        await const MethodChannel(
          'org.huideng.counter/notes',
        ).invokeMethod('shareText', url);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('个人主页链接暂未配置')));
      }
    }
  }

  bool savingVisibility = false;
  Future<void> setVisibility(String key, bool value) async {
    if (savingVisibility) return;
    setState(() => savingVisibility = true);
    try {
      await widget.app.cloud!.client!.rpc(
        'community_profile_v1',
        params: {
          'p_user': widget.userId,
          'p_data': {key: value},
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置未保存，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => savingVisibility = false);
    }
  }

  Future<void> edit() async {
    final bio = TextEditingController(text: data?['profile']?['bio'] ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('个性简介'),
        content: TextField(controller: bio, maxLength: 500, maxLines: 4),
        actions: [
          IconButton(
            onPressed: () => shareProfile(copy: false),
            icon: const Icon(Icons.share_outlined),
            tooltip: '分享',
          ),
          IconButton(
            onPressed: () => shareProfile(copy: true),
            icon: const Icon(Icons.link_outlined),
            tooltip: '复制链接',
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, bio.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    bio.dispose();
    if (value == null) return;
    try {
      await widget.app.cloud!.client!.rpc(
        'community_profile_v1',
        params: {
          'p_user': widget.userId,
          'p_data': {
            'bio': value,
            'show_account': data?['profile']?['show_account'] == true,
          },
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = data?['profile'] as Map?;
    final posts = (data?['posts'] as List? ?? []).where(
      (p) =>
          tab == 'all' ||
          p['post_kind'] == tab ||
          tab == 'resources' && p['category_id'] == 'resources' ||
          tab == 'images' &&
              ((p['image_urls'] as List? ?? []).isNotEmpty ||
                  p['has_image'] == true),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人主页'),
        actions: [
          if (own)
            TextButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ForumComposePage(
                      app: widget.app,
                      repository: ForumRepository(
                        ForumRemote(widget.app.cloud!.client!),
                        HomeMessageCache(cacheKey: 'forum_feed'),
                      ),
                      categories: forumCategories,
                      initialKind: 'article',
                    ),
                  ),
                );
                if (mounted) await load();
              },
              child: const Text('写文章'),
            ),
          if (own)
            IconButton(onPressed: edit, icon: const Icon(Icons.edit_outlined)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          children: [
            ListTile(
              leading: InkWell(
                onTap: !own
                    ? null
                    : () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatAvatarPage(
                              app: widget.app,
                              remote: ChatRemote(
                                widget.app.cloud!.client!,
                                widget.userId,
                              ),
                            ),
                          ),
                        );
                        if (mounted) await load();
                      },
                child: ChatAvatar(
                  remote: ChatRemote(
                    widget.app.cloud!.client!,
                    widget.app.cloud!.client!.auth.currentUser?.id ?? '',
                  ),
                  userId: widget.userId,
                ),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile?['nickname'] ?? '学友'),
                  if (profile?['personal_number'] != null)
                    Text(
                      '个人号：${profile!['personal_number']}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
              subtitle: (profile?['bio'] as String? ?? '').isEmpty
                  ? null
                  : Text(profile?['bio'] as String),
            ),
            if (follow != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('profile-following'),
                      onPressed: () => openPeople(false),
                      child: Text('关注 ${forumCount(follow!['following_count'] as num?)}'),
                    ),
                    TextButton(
                      key: const ValueKey('profile-followers'),
                      onPressed: () => openPeople(true),
                      child: Text('粉丝 ${forumCount(follow!['followers'] as num?)}'),
                    ),
                    const Spacer(),
                    if (!own && follow!['self'] != true)
                      follow!['following'] == true
                          ? OutlinedButton(
                              key: const ValueKey('profile-follow-button'),
                              onPressed: followBusy ? null : toggleFollow,
                              child: Text(
                                follow!['followed_by'] == true ? '互相关注' : '已关注',
                              ),
                            )
                          : FilledButton(
                              key: const ValueKey('profile-follow-button'),
                              onPressed: followBusy ? null : toggleFollow,
                              child: Text(
                                follow!['followed_by'] == true ? '回关' : '关注',
                              ),
                            ),
                  ],
                ),
              ),
            if (own) ...[
              SwitchListTile(
                title: const Text('公开显示个人号'),
                value: profile?['show_account'] == true,
                onChanged: (v) async {
                  try {
                    await widget.app.cloud!.client!.rpc(
                      'community_profile_v1',
                      params: {
                        'p_user': widget.userId,
                        'p_data': {
                          'bio': profile?['bio'] ?? '',
                          'show_account': v,
                        },
                      },
                    );
                    await load();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('保存失败')));
                    }
                  }
                },
              ),
              ListTile(
                title: const Text('我的群组'),
                onTap: () => chooseMyGroup(context, widget.app),
              ),
              ListTile(
                title: const Text('我的共修'),
                onTap: () => choosePracticeGroup(context, widget.app),
              ),
            ],
            if (own)
              ListTile(
                title: const Text('我的结缘'),
                leading: const Icon(Icons.volunteer_activism_outlined),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MyJieyuanPage(app: widget.app),
                  ),
                ),
              ),
            if (own)
              SwitchListTile(
                title: const Text('个人资料夹对外开放'),
                subtitle: Text(
                  profile?['public_resources'] == true
                      ? '对外开放，原文件权限仍有效'
                      : '仅自己可见',
                ),
                value: profile?['public_resources'] == true,
                onChanged: data == null || savingVisibility
                    ? null
                    : (v) => setVisibility('public_resources', v),
              ),
            if (own || profile?['public_resources'] == true)
              ListTile(
                title: Text(own ? '个人资料夹' : 'TA的资料夹'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PersonalLibraryPage(
                      app: widget.app,
                      userId: own ? null : widget.userId,
                      legacyPage: SavedResourcesPage(
                        app: widget.app,
                        userId: own ? null : widget.userId,
                      ),
                    ),
                  ),
                ),
              ),
            if (error != null) ListTile(title: Text(error!), onTap: load),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in {
                    'all': '全部',
                    'status': '动态',
                    'article': '文章',
                    'images': '图片',
                    'resources': '资料',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: ChoiceChip(
                        label: Text(e.value),
                        selected: tab == e.key,
                        onSelected: (_) => setState(() => tab = e.key),
                      ),
                    ),
                ],
              ),
            ),
            if (own)
              SwitchListTile(
                title: const Text('我的收藏对外开放'),
                subtitle: Text(
                  profile?['public_bookmarks'] == true
                      ? '对外展示收藏的公开帖子'
                      : '仅自己可见',
                ),
                value: profile?['public_bookmarks'] == true,
                onChanged: data == null || savingVisibility
                    ? null
                    : (v) => setVisibility('public_bookmarks', v),
              ),
            if (own || profile?['public_bookmarks'] == true)
              ListTile(
                leading: const Icon(Icons.bookmark_outline),
                title: Text(own ? '我的收藏' : 'TA的收藏'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => own
                        ? ForumPage(app: widget.app, initialSort: 'bookmarks')
                        : ProfileBookmarksPage(
                            app: widget.app,
                            userId: widget.userId,
                          ),
                  ),
                ),
              ),
            for (final raw in posts)
              ListTile(
                title: getPostDisplayTitle(raw).isEmpty
                    ? null
                    : Text(getPostDisplayTitle(raw)),
                subtitle: Text(
                  raw['body'],
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ForumDetailPage(
                        app: widget.app,
                        row: Map<String, dynamic>.from(raw),
                        repository: ForumRepository(
                          ForumRemote(widget.app.cloud!.client!),
                          HomeMessageCache(cacheKey: 'forum_feed'),
                        ),
                      ),
                    ),
                  );
                  // The author may have edited text or images there.
                  if (mounted) await load();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class ProfileBookmarksPage extends StatefulWidget {
  final AppController app;
  final String userId;
  const ProfileBookmarksPage({
    super.key,
    required this.app,
    required this.userId,
  });
  @override
  State<ProfileBookmarksPage> createState() => _ProfileBookmarksPageState();
}

class _ProfileBookmarksPageState extends State<ProfileBookmarksPage> {
  List rows = [];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.app.cloud!.client!.rpc(
        'community_collection_v1',
        params: {'p_user': widget.userId, 'p_kind': 'bookmarks'},
      );
      if (mounted) {
        setState(() {
          rows = result as List;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          rows = [];
          error = '收藏未公开或暂时无法加载';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('TA的收藏')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (error != null) ListTile(title: Text(error!), onTap: load),
          if (error == null && rows.isEmpty)
            const ListTile(title: Text('暂无公开收藏')),
          for (final row in rows)
            ListTile(
              title: getPostDisplayTitle(row).isEmpty
                  ? null
                  : Text(getPostDisplayTitle(row)),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ForumDetailPage(
                    app: widget.app,
                    row: Map<String, dynamic>.from(row),
                    repository: ForumRepository(
                      ForumRemote(widget.app.cloud!.client!),
                      HomeMessageCache(cacheKey: 'forum_feed'),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
