import 'masonry_posts.dart';
import 'forum_comments.dart';
import 'windows_display.dart';
import 'forum_image_viewer.dart';
import '../data/remote/forum_social.dart';
import 'cloud_drive_page.dart';
import 'my_page.dart' show StorageStatusPage;
import 'jieyuan_fields.dart';
import 'jieyuan_actions.dart';
import '../domain/post_display.dart';
import 'chat_avatar.dart';
import 'profile_navigation.dart';
import '../data/remote/chat_remote.dart';
import 'settings_page.dart';
import 'forum_edit_page.dart';
import '../data/repositories/forum_edits.dart';
import 'dart:convert';
import 'shared_rich_editor.dart';
import 'public_profile_page.dart';
import '../services/content_transfer.dart';
import 'routed_image.dart';
import 'chat_page.dart';
import 'forum_chat_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import 'forum_compose_page.dart';
import '../core/app_links_controller.dart';
import '../data/local/home_message_cache.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';

// Keep persisted IDs compatible with existing clients and post links.
const forumBoards = {
  'jieyuan': ['结缘', 'Sharing'],
  'feedback': ['综合', 'General'],
  'practice': ['活动', 'Activities'],
  'study': ['学修', 'Study'],
};
const forumCategories = {
  ...forumBoards,
  'resources': ['资料分享', 'Resources'],
};
const forumDescriptions = {
  'jieyuan': ['免费结缘、有偿转让与求结缘 · 通过私聊沟通', 'Share or find Buddhist items'],
  'study': ['佛法问答、闻思讨论、修行心得与经论交流', 'Questions, reflections and Buddhist study'],
  'practice': ['共修通知、报名、功课与法会活动', 'Group practice, events and announcements'],
  'resources': ['经论、讲义、图片、音视频与工具', 'Texts, images, audio, video and tools'],
  'feedback': ['日常分享、交流与讨论', 'Everyday sharing and discussion'],
};
String forumSection(String? id) =>
    ['questions', 'experience'].contains(id) ? 'study' : id ?? '';
String forumSectionName(AppController app, dynamic id) {
  final names = forumCategories[forumSection(id as String?)];
  return names == null ? app.text('学修', 'Study') : app.text(names[0], names[1]);
}

class ForumPage extends StatefulWidget {
  final AppController app;
  final ForumRepository? repository;
  final bool embedded;
  final String category, initialSort;
  const ForumPage({
    super.key,
    required this.app,
    this.repository,
    this.embedded = false,
    this.category = '',
    this.initialSort = 'latest',
  });
  @override
  State<ForumPage> createState() => _ForumPageState();
}

class _ForumPageState extends State<ForumPage> {
  final search = TextEditingController();
  String query = '';
  String activeFilter = 'all';
  late String sort;
  // The 推荐 (For you) sort to restore when leaving the 关注 channel.
  String recommendSort = 'latest';
  late String selectedCategory;
  bool listMode = false;
  bool boards = false, busy = false, more = false, cached = false;
  List<Map<String, dynamic>> items = [], sections = [];
  String? error;
  int generation = 0, nextOffset = 0;
  AppController get app => widget.app;
  bool get personal =>
      ['mine', 'my_replies', 'bookmarks', 'completed'].contains(sort);
  ForumRepository get repository =>
      widget.repository ??
      ForumRepository(
        app.cloud?.client == null ? null : ForumRemote(app.cloud!.client!),
        HomeMessageCache(cacheKey: 'forum_feed'),
      );
  String tr(String a, String b) => app.text(a, b);
  @override
  void initState() {
    super.initState();
    selectedCategory = widget.category;
    listMode = app.preferences['forum_layout_mode'] == 'list';
    boards = widget.initialSort == 'boards';
    sort = boards ? 'latest' : widget.initialSort;
    load();
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  // Order matches the visible chip row: 全部→最新→热门→板块→结缘.
  static const channelOrder = ['all', 'latest', 'hot', 'boards', 'jieyuan'];

  void selectChannel(String key) {
    activeFilter = key;
    boards = key == 'boards';
    selectedCategory = key == 'jieyuan' ? 'jieyuan' : '';
    sort = key == 'hot' ? 'hot' : 'latest';
    load();
  }

  // A plain onHorizontalDragEnd (not a generic pan) only wins the gesture
  // arena when the drag is predominantly horizontal, so normal vertical
  // list scrolling / pull-to-refresh is unaffected. Nested widgets with
  // their own horizontal recognizer (post image carousels) sit deeper in
  // the tree and are hit-tested first, so they naturally take priority
  // over this outer detector for the same gesture.
  void swipeChannel(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 200) return;
    final i = channelOrder.indexOf(activeFilter);
    if (i < 0) return;
    if (velocity < 0 && i < channelOrder.length - 1) {
      selectChannel(channelOrder[i + 1]);
    } else if (velocity > 0 && i > 0) {
      selectChannel(channelOrder[i - 1]);
    }
  }

  Future<void> load({bool append = false}) async {
    final ticket = ++generation, offset = append ? nextOffset : 0;
    setState(() {
      busy = true;
      error = null;
      if (!append) items = [];
    });
    try {
      if (selectedCategory.startsWith('jieyuan') && repository.remote != null) {
        final c = await repository.remote!.client.rpc('jieyuan_permissions');
        if (c['enabled'] != true || c['permissions']['enter'] != true) {
          throw StateError('结缘暂未开放，或当前等级没有访问权限');
        }
      }
      if (boards) {
        final result = await repository.sections();
        if (!mounted || ticket != generation) return;
        setState(() {
          sections = result;
          cached = false;
          more = false;
        });
      } else {
        final feed = await repository.feed(
          search: query,
          category: selectedCategory,
          sort: sort,
          offset: offset,
          after: append && sort == 'following' && items.isNotEmpty
              ? items.last
              : null,
        );
        if (!mounted || ticket != generation) return;
        setState(() {
          items = {
            for (final row in [if (append) ...items, ...feed.items])
              row['id']: row,
          }.values.toList();
          more = feed.hasMore;
          cached = feed.cached;
          nextOffset = offset + feed.items.length;
        });
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(
          () => error = forumServiceMissing(e)
              ? tr(
                  '论坛服务需要更新，请执行 016 配置脚本。',
                  'Forum service requires migration 016.',
                )
              : forumFailure(app, e),
        );
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> website() async {
    final url = AppLinksController.validUrl(app.forumUrl);
    try {
      if (url == null ||
          !await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          )) {
        throw StateError('unavailable');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('无法打开论坛网址', 'Could not open forum website')),
          ),
        );
      }
    }
  }

  Future<void> openList({String category = '', String mode = 'latest'}) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ForumPage(
          app: app,
          repository: repository,
          category: category,
          initialSort: mode,
        ),
      ),
    );
    if (mounted) await load();
  }

  void searchNow() {
    query = search.text.trim();
    boards = false;
    load();
  }

  Future<void> layoutSettings() async {
    final choice = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('版面设置')),
            ListTile(
              title: const Text('双列'),
              leading: const Icon(Icons.grid_view),
              trailing: !listMode ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              title: const Text('单列'),
              leading: const Icon(Icons.view_agenda_outlined),
              trailing: listMode ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) await layout(choice);
  }

  Future<void> layout(bool list) async {
    setState(() => listMode = list);
    try {
      await app.set('forum_layout_mode', list ? 'list' : 'grid');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '布局已切换，但偏好保存失败',
                'Layout changed; preference could not be saved',
              ),
            ),
          ),
        );
      }
    }
  }

  final liking = <String>{};
  Future<void> likePost(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    if (liking.contains(id)) return;
    if (!repository.signedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('请先登录后点赞', 'Sign in to like posts'))),
      );
      return;
    }
    setState(() => liking.add(id));
    try {
      final detail = await repository.action('detail', {'post_id': id});
      await repository.action('like', {
        'post_id': id,
        'enabled': detail['liked'] != true,
      });
      final updated = await repository.action('detail', {'post_id': id});
      if (mounted) {
        setState(() {
          row.addAll(Map<String, dynamic>.from(updated['post']));
          row['liked'] = updated['liked'];
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(forumFailure(app, e))));
      }
    } finally {
      if (mounted) setState(() => liking.remove(id));
    }
  }

  Widget postCard(Map<String, dynamic> row) => ForumPostCard(
    app: app,
    row: row,
    listMode: listMode,
    onLike: cached || liking.contains(row['id']) ? null : () => likePost(row),
    onTap: () async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ForumDetailPage(
            app: app,
            row: row,
            cached: cached,
            repository: repository,
            siblings: items,
            index: items.indexOf(row),
          ),
        ),
      );
      if (mounted) await load();
    },
  );
  Future<void> openSearch() async {
    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('搜索', 'Search')),
        content: TextField(
          controller: search,
          autofocus: true,
          maxLength: 200,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: tr('标题、正文、作者、文件名', 'Title, text, author or filename'),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () {
              search.clear();
              Navigator.pop(ctx, true);
            },
            child: Text(tr('清除搜索', 'Clear search')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('搜索', 'Search')),
          ),
        ],
      ),
    );
    if (submit == true && mounted) searchNow();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      titleSpacing: 8,
      leadingWidth: 40,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final iconSize = constraints.maxWidth >= 330 ? 36.0 : 32.0;
          return Row(
            children: [
              if (widget.category.isNotEmpty ||
                  sort == 'mine' ||
                  sort == 'my_replies' ||
                  sort == 'bookmarks')
                Expanded(
                  flex: 2,
                  child: Text(
                    widget.category.isNotEmpty
                        ? forumSectionName(app, widget.category)
                        : sort == 'mine'
                        ? tr('我的帖子', 'My posts')
                        : sort == 'my_replies'
                        ? tr('我的回复', 'My replies')
                        : sort == 'bookmarks'
                        ? tr('我的收藏', 'Bookmarks')
                        : tr('红书', 'Hongshu'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: PopupMenuButton<String>(
                    tooltip: tr('个人菜单', 'Personal menu'),
                    padding: EdgeInsets.zero,
                    iconSize: iconSize,
                    icon: const Icon(
                      Icons.person_outline,
                      color: Color(0xFFE18289),
                    ),
                    onSelected: (v) {
                      if (v == 'profile') {
                        final user = app.cloud?.client?.auth.currentUser;
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => user == null
                                ? SettingsPage(app: app)
                                : PublicProfilePage(app: app, userId: user.id),
                          ),
                        );
                      } else if (v == 'pending_edits') {
                        final client = repository.remote?.client;
                        if (client != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  ForumPendingPage(edits: ForumEdits(client)),
                            ),
                          );
                        }
                      } else if (v == 'website') {
                        website();
                      } else {
                        openList(mode: v);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'pending_edits',
                        child: Text('待同步修改'),
                      ),
                      PopupMenuItem(
                        value: 'profile',
                        child: Text(tr('个人主页', 'Personal profile')),
                      ),
                      PopupMenuItem(
                        value: 'mine',
                        child: Text(tr('我的帖子', 'My posts')),
                      ),
                      PopupMenuItem(
                        value: 'my_replies',
                        child: Text(tr('我的回复', 'My replies')),
                      ),
                      PopupMenuItem(
                        value: 'bookmarks',
                        child: Text(tr('我的收藏', 'Bookmarks')),
                      ),
                      PopupMenuItem(
                        value: 'website',
                        child: Text(tr('原论坛', 'Website')),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: TextButton(
                  key: const ValueKey('forum-resources'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CloudDrivePage(
                        app: app,
                        settingsPage: StorageStatusPage(app: app),
                      ),
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE8BD57),
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      tr('资料分享', 'Resources'),
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: IconButton(
                  tooltip: tr('搜索', 'Search'),
                  onPressed: openSearch,
                  iconSize: iconSize,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minHeight: 48),
                  color: const Color(0xFF66C78B),
                  icon: const Icon(Icons.search),
                ),
              ),
              Expanded(
                flex: 2,
                child: IconButton(
                  tooltip: tr('版面设置', 'Layout settings'),
                  onPressed: layoutSettings,
                  iconSize: iconSize,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minHeight: 48),
                  color: const Color(0xFFBB91E7),
                  icon: Icon(
                    listMode ? Icons.grid_view : Icons.view_list_outlined,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
    floatingActionButton: FloatingActionButton.extended(
      heroTag: 'new-forum-post',
      backgroundColor: Theme.of(context).colorScheme.primary,
      foregroundColor: Theme.of(context).colorScheme.onPrimary,
      icon: const Icon(Icons.add),
      label: Text(tr('发帖', 'New post')),
      onPressed: () async {
        final sent = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ForumComposePage(
              app: app,
              repository: repository,
              categories: forumCategories,
              initialCategory: widget.category.isEmpty
                  ? 'feedback'
                  : widget.category.split(':').first,
            ),
          ),
        );
        if (sent == true && mounted) await load();
      },
    ),
    bottomNavigationBar: personal || widget.embedded
        ? null
        : NavigationBar(
            height: 58,
            selectedIndex: boards
                ? 2
                : sort == 'hot'
                ? 1
                : 0,
            indicatorColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            onDestinationSelected: (index) {
              if (index == 3) {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => ChatPage(app: app)),
                );
                return;
              }
              if (index == 2 && widget.category.isNotEmpty) {
                openList(mode: 'boards');
                return;
              }
              boards = index == 2;
              if (!boards) sort = index == 1 ? 'hot' : 'latest';
              load();
            },
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.schedule_outlined),
                label: tr('最新', 'Latest'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.local_fire_department_outlined),
                label: tr('热门', 'Popular'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.grid_view_outlined),
                label: tr('板块', 'Boards'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                label: tr('消息', 'Messages'),
              ),
            ],
          ),
    body: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: readingPageMaxWidth(760)),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: widget.embedded ? swipeChannel : null,
          child: Column(
          children: [
            if (widget.embedded)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in const {
                      'all': ['全部', 'All'],
                      'latest': ['最新', 'Latest'],
                      'hot': ['热门', 'Popular'],
                      'boards': ['板块', 'Boards'],
                      'jieyuan': ['结缘', 'Sharing'],
                    }.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 4,
                        ),
                        child: ChoiceChip(
                          label: Text(tr(entry.value[0], entry.value[1])),
                          selected: activeFilter == entry.key,
                          onSelected: (_) => selectChannel(entry.key),
                        ),
                      ),
                  ],
                ),
              ),
            if (selectedCategory.startsWith('jieyuan') && !personal)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in {'': '全部', ...jieyuanTypes}.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(e.value),
                          selected:
                              selectedCategory ==
                              'jieyuan${e.key.isEmpty ? '' : ':${e.key}'}',
                          onSelected: (_) {
                            selectedCategory =
                                'jieyuan${e.key.isEmpty ? '' : ':${e.key}'}';
                            load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            if (busy) const LinearProgressIndicator(),
            if (cached)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  tr(
                    '离线缓存 · 图片及附件需要网络',
                    'Offline cache · Media requires a connection',
                  ),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Text(error!),
                    TextButton(
                      onPressed: busy ? null : load,
                      child: Text(tr('重试', 'Retry')),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    // Following needs an identity; guests have an anonymous one.
                    if (!widget.embedded &&
                        !boards &&
                        widget.category.isEmpty &&
                        !personal &&
                        query.isEmpty &&
                        repository.remote?.client.auth.currentUser != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SegmentedButton<bool>(
                          key: const ValueKey('forum-channel'),
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: false,
                              label: Text(tr('推荐', 'For you')),
                            ),
                            ButtonSegment(
                              value: true,
                              label: Text(tr('关注', 'Following')),
                            ),
                          ],
                          selected: {sort == 'following'},
                          onSelectionChanged: (v) {
                            if (v.first == (sort == 'following')) return;
                            if (v.first) {
                              recommendSort = sort;
                              sort = 'following';
                              selectedCategory = '';
                            } else {
                              sort = recommendSort;
                            }
                            load();
                          },
                        ),
                      ),
                    if (sort == 'following' &&
                        items.isEmpty &&
                        !busy &&
                        error == null)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr(
                            '这里显示你关注的作者发布的帖子（按发布时间）。\n在帖子顶部或作者主页点“关注”即可。',
                            'Posts from people you follow appear here. Tap Follow on a post or profile.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (!widget.embedded &&
                        !boards &&
                        widget.category.isEmpty &&
                        sort != 'following')
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final entry in {
                              '': ['全部', 'All'],
                              ...forumBoards,
                            }.entries)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 8,
                                  bottom: 8,
                                ),
                                child: ChoiceChip(
                                  label: Text(
                                    tr(entry.value[0], entry.value[1]),
                                  ),
                                  selected: selectedCategory == entry.key,
                                  onSelected: (_) {
                                    selectedCategory = entry.key;
                                    load();
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (boards)
                      for (final entry in forumBoards.entries)
                        Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.all(18),
                            title: Text(tr(entry.value[0], entry.value[1])),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr(
                                      forumDescriptions[entry.key]![0],
                                      forumDescriptions[entry.key]![1],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  for (final section in sections.where(
                                    (s) => s['id'] == entry.key,
                                  )) ...[
                                    Text(
                                      tr(
                                        '帖子：${section['count']}',
                                        'Posts: ${section['count']}',
                                      ),
                                    ),
                                    Text(
                                      section['latest_title'] as String? ??
                                          tr('暂无帖子', 'No posts yet'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => openList(category: entry.key),
                          ),
                        ),
                    if (!boards) ...[
                      if (items.isEmpty &&
                          !busy &&
                          error == null &&
                          sort != 'following')
                        Padding(
                          padding: const EdgeInsets.all(36),
                          child: Text(
                            tr('暂无符合条件的帖子', 'No matching posts'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      if (listMode)
                        for (final item in items) postCard(item)
                      else
                        MasonryPosts(
                          children: [for (final item in items) postCard(item)],
                        ),
                      if (more)
                        TextButton(
                          onPressed: busy ? null : () => load(append: true),
                          child: Text(tr('加载更多', 'Load more')),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    ),
  );
}

Widget forumImage(String url) => RoutedImage(
  url,
  cacheWidth: 768,
  fit: BoxFit.cover,
  errorBuilder: (_, _, _) => const SizedBox(
    height: 120,
    child: Center(child: Icon(Icons.broken_image_outlined)),
  ),
);
List<String> forumImages(Map<String, dynamic> row) =>
    (row['image_urls'] as List? ?? [])
        .map(AppLinksController.validUrl)
        .whereType<String>()
        .toList();

Widget forumAuthorAvatar(AppController app, Map row, {double radius = 10}) {
  final client = app.cloud?.client;
  final user = client?.auth.currentUser;
  if (row['author_user_id'] != null) {
    return ChatAvatar(
      app: app,
      publicClient: client,
      remote: client != null && user != null
          ? ChatRemote(client, user.id)
          : null,
      userId: row['author_user_id'] as String,
      radius: radius,
    );
  }
  return Builder(builder: (context) => GestureDetector(
    onTap: () => openUserProfile(context, app),
    child: CircleAvatar(
      radius: radius,
      child: Icon(Icons.person_outline, size: radius * 1.5),
    ),
  ),
  );
}

void openForumAuthor(BuildContext context, AppController app, Map row) {
  final id = row['author_user_id'];
  openUserProfile(context, app, userId: id is String ? id : null);
}

class ForumPostCard extends StatelessWidget {
  final AppController app;
  final Map<String, dynamic> row;
  final VoidCallback onTap;
  final VoidCallback? onLike;
  final bool listMode;
  const ForumPostCard({
    super.key,
    required this.app,
    required this.row,
    required this.onTap,
    this.onLike,
    this.listMode = false,
  });
  Widget countButton(
    String label,
    IconData icon,
    dynamic count,
    VoidCallback? onPressed,
  ) => Tooltip(
    message: '$label ${count ?? 0}',
    child: Semantics(
      label: '$label ${count ?? 0}',
      button: true,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                children: [
                  Icon(icon, size: 15),
                  const SizedBox(width: 2),
                  Text(
                    compactPostCount(count),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final images = forumImages(row), title = getPostDisplayTitle(row);
    final explicit = (row['title'] as String? ?? '').trim().isNotEmpty;
    final body = (row['body'] as String? ?? '').trim();
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (images.isNotEmpty)
              AspectRatio(
                aspectRatio: listMode ? 4 / 3 : 4 / 5,
                child: forumImage(images.first),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (row['is_pinned'] == true)
                    Text(
                      app.text('置顶', 'Pinned'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  if (row['jieyuan'] is Map)
                    Text(
                      '${jieyuanSummary(row['jieyuan'])} · ${row['jieyuan']['region'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.amber),
                    ),
                  if (title.isNotEmpty && (explicit || images.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        title,
                        softWrap: true,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (body.isNotEmpty &&
                      (images.isEmpty || (explicit && body != title)))
                    Padding(
                      padding: const EdgeInsets.only(top: 3, left: 2, right: 2),
                      child: Text(
                        body,
                        maxLines: images.isEmpty ? 7 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => openForumAuthor(context, app, row),
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              children: [
                                forumAuthorAvatar(app, row, radius: 9),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    row['author_name'] as String? ?? '游客',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      countButton(
                        '点赞',
                        row['liked'] == true
                            ? Icons.favorite
                            : Icons.favorite_border,
                        row['like_count'],
                        onLike,
                      ),
                      countButton(
                        '评论',
                        Icons.chat_bubble_outline,
                        row['reply_count'],
                        onTap,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ForumDetailPage extends StatefulWidget {
  final AppController app;
  final Map<String, dynamic> row;
  final bool cached;
  final ForumRepository? repository;
  /// The list this post was opened from (current channel/sort order) and
  /// this post's position in it, so up/down swipe moves along that same
  /// order. Null when opened without a list context (e.g. a shared link),
  /// which disables the gesture.
  final List<Map<String, dynamic>>? siblings;
  final int? index;
  const ForumDetailPage({
    super.key,
    required this.app,
    required this.row,
    this.cached = false,
    this.repository,
    this.siblings,
    this.index,
  });
  @override
  State<ForumDetailPage> createState() => _ForumDetailPageState();
}

class _ForumDetailPageState extends State<ForumDetailPage> {
  AppController get app => widget.app;
  late Map<String, dynamic> row;
  List<Map<String, dynamic>> replies = [];
  bool busy = false, liked = false, bookmarked = false, available = true;
  String? error;
  bool get cached => widget.cached;
  // Social layer (migration 202609250071). null = not loaded yet,
  // false = unavailable, in which case the legacy reply list is shown.
  bool? social;
  bool viewed = false, following = false, followBusy = false;
  Map<String, dynamic> stats = {};
  final commentsKey = GlobalKey<ForumCommentsState>();
  ForumSocial? get socialApi {
    final client = widget.repository?.remote?.client;
    return client?.auth.currentUser == null ? null : ForumSocial(client!);
  }

  bool get ownPost =>
      row['owned'] == true ||
      (row['author_user_id'] != null &&
          row['author_user_id'] == socialApi?.userId);

  late int? siblingIndex = widget.index;
  double overscroll = 0;
  @override
  void initState() {
    super.initState();
    row = widget.row;
    refresh();
  }

  // Fed by the ListView's own scroll notifications (see build()): normal
  // scrolling inside the post never reaches here, only genuine overscroll
  // once the list is already at its top/bottom edge, so mid-article
  // scrolling can never misfire a post switch. A short post that never
  // fills the viewport is already "at both edges" from the first pixel of
  // drag, so it behaves like a full-screen swipeable card, as intended.
  void trackOverscroll(double delta) {
    overscroll += delta;
    if (overscroll > 120) {
      overscroll = 0;
      switchPost(1);
    } else if (overscroll < -120) {
      overscroll = 0;
      switchPost(-1);
    }
  }

  Future<void> switchPost(int direction) async {
    final siblings = widget.siblings;
    final index = siblingIndex;
    if (siblings == null || index == null) return;
    final target = index + direction;
    if (target < 0 || target >= siblings.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            target < 0
                ? app.text('已经是第一篇', 'This is the first post')
                : app.text('已经是最后一篇', 'This is the last post'),
          ),
        ),
      );
      return;
    }
    setState(() {
      row = siblings[target];
      siblingIndex = target;
    });
    await refresh();
  }

  /// First call counts one read (per user per day); later calls only reload.
  Future<void> loadSocial() async {
    final api = socialApi;
    if (api == null || !available) {
      if (mounted) setState(() => social = false);
      return;
    }
    try {
      final slug = row['share_slug'] as String?;
      final value = viewed
          ? await api.call('post_stats', {'post_id': row['id'], 'slug': ?slug})
          : await api.view(row['id'] as String, slug: slug);
      viewed = true;
      if (!mounted) return;
      setState(() {
        stats = value;
        following = value['following_author'] == true;
        liked = value['liked'] == true;
        bookmarked = value['bookmarked'] == true;
        social = true;
      });
    } catch (_) {
      if (mounted && social != true) setState(() => social = false);
    }
  }

  Future<void> toggleFollow() async {
    final api = socialApi, author = row['author_user_id'];
    if (api == null || author is! String || followBusy) {
      if (api == null) {
        setState(() => error = app.text('聊天身份尚未就绪，请稍后再试。', 'Identity not ready yet.'));
      }
      return;
    }
    setState(() => followBusy = true);
    try {
      final state = await api.follow(author, !following);
      if (mounted) setState(() => following = state['following'] == true);
    } catch (e) {
      if (mounted) setState(() => error = socialFailure(app, e));
    } finally {
      if (mounted) setState(() => followBusy = false);
    }
  }

  int count(String key) =>
      ((stats[key] ?? row[key]) as num? ?? 0).toInt();

  Future<void> refresh() async {
    if (widget.repository == null) return;
    try {
      final data = await widget.repository!.action('detail', {
        'post_id': row['id'],
        'slug': row['share_slug'],
      });
      if (mounted) {
        setState(() {
          row = Map<String, dynamic>.from(data['post'] as Map);
          replies = (data['replies'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          liked = data['liked'] == true;
          bookmarked = data['bookmarked'] == true;
          error = null;
          available = true;
        });
        await loadSocial();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = forumFailure(app, e);
          available = false;
        });
      }
    }
  }

  Future<void> react(String kind) async {
    if (busy || widget.repository == null) return;
    if (!widget.repository!.signedIn) {
      setState(
        () => error = app.text(
          '请先在“计数 → 设置 → 账号与同步”登录。',
          'Sign in under Counter → Settings → Account and sync.',
        ),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await widget.repository!.action(kind, {
        'post_id': row['id'],
        'slug': row['share_slug'],
        'enabled': kind == 'like' ? !liked : !bookmarked,
      });
      await refresh();
      if (mounted && kind == 'bookmark') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              bookmarked ? '已收藏，可在 我的收藏 中找到' : '已取消收藏（原帖子不受影响）',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = forumFailure(app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reply() async {
    if (social == true && commentsKey.currentState != null) {
      await commentsKey.currentState!.compose();
      return;
    }
    if (widget.repository == null) return;
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ForumComposePage(
          app: app,
          repository: widget.repository!,
          categories: forumCategories,
          postId: row['id'] as String,
          shareSlug: row['share_slug'] as String?,
        ),
      ),
    );
    if (sent == true && mounted) await refresh();
  }

  bool get canManage =>
      widget.repository?.remote?.client.auth.currentUser?.id != null &&
      row['author_user_id'] ==
          widget.repository!.remote!.client.auth.currentUser!.id;

  Future<void> managePost(String operation) async {
    if (!canManage || busy) return;
    final edits = ForumEdits(widget.repository!.remote!.client);
    try {
      final pending = await edits.pending();
      if (!mounted) return;
      if (pending.any((p) => p['post_id'] == row['id'])) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ForumPendingPage(edits: edits),
          ),
        );
      } else if (operation == 'edit') {
        await Navigator.push(
          context,
          MaterialPageRoute<bool>(
            builder: (_) => ForumEditPage(post: Map.of(row), edits: edits),
          ),
        );
      } else {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除自己发布的文章？'),
            content: const Text('云端同步后文章将不再公开显示。断网时先保存在本机，联网后同步删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除文章'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        setState(() => busy = true);
        await edits.save(row, 'delete');
        await edits.sync();
        final left = await edits.pending();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              left.any((p) => p['post_id'] == row['id'])
                  ? '删除请求已保存本地，请在个人 → 待同步修改查看。'
                  : '文章已删除',
            ),
          ),
        );
        Navigator.pop(context);
        return;
      }
      if (mounted) await refresh();
    } catch (_) {
      if (mounted) setState(() => error = '操作未完成，请查看个人 → 待同步修改；本地已保存的请求会保留。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> shareOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(app.text('分享给好友', 'Share with a friend')),
              onTap: () => Navigator.pop(ctx, 'chat'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(app.text('分享到群聊', 'Share to a group')),
              onTap: () => Navigator.pop(ctx, 'group'),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(app.text('保存到我的笔记', 'Save to my notes')),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            if (row['author_user_id'] != null)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('作者主页'),
                onTap: () => Navigator.pop(ctx, 'profile'),
              ),
            if (row['owned'] == true)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text(app.text('修改可见范围', 'Visibility')),
                onTap: () => Navigator.pop(ctx, 'visibility'),
              ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(app.text('复制帖子链接', 'Copy post link')),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(app.text('系统分享', 'System share')),
              onTap: () => Navigator.pop(ctx, 'external'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'profile') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              PublicProfilePage(app: app, userId: row['author_user_id']),
        ),
      );
      return;
    }
    if (choice == 'chat' || choice == 'group') {
      if (row['access_level'] == 'private') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先将内容改为公开或仅链接可见')));
        return;
      }
      await shareForumToChat(context, app, row, groups: choice == 'group');
    }
    if (choice == 'note') {
      await ContentTransfer(app).postToNote(row);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(app.text('已保存独立笔记副本', 'Saved a private copy')),
          ),
        );
      }
    }
    if (!mounted) return;
    if (choice == 'visibility') {
      final level = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in {
                'public': '公开',
                'link_only': '仅链接可见',
                'private': '私密',
              }.entries)
                ListTile(
                  title: Text(v.value),
                  onTap: () => Navigator.pop(ctx, v.key),
                ),
            ],
          ),
        ),
      );
      if (level != null) {
        await widget.repository!.action('visibility', {
          'post_id': row['id'],
          'access_level': level,
        });
        await refresh();
      }
    }
    if (choice == 'link') {
      try {
        var slug = row['share_slug'];
        if (row['owned'] == true) {
          slug = (await widget.repository!.action('share', {
            'post_id': row['id'],
          }))['slug'];
        }
        final config = await widget.repository!.remote!.client
            .from('community_config')
            .select()
            .single();
        final base = config['public_base_url'] as String? ?? '';
        if (base.isEmpty || slug == null) throw StateError('网页入口尚未配置，或此内容为私密');
        await Clipboard.setData(
          ClipboardData(text: '${base.replaceAll(RegExp(r'/+$'), '')}/p/$slug'),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('网页链接已复制')));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂时无法生成链接，请确认网页入口已配置且内容不是私密。')),
          );
        }
      }
    }
    if (choice == 'external') await share();
  }

  Future<void> share() async {
    if (row['access_level'] == 'private') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('私密内容不能生成公开分享链接')));
      return;
    }
    String link = '';
    try {
      final config = await widget.repository!.remote!.client
          .from('community_config')
          .select()
          .single();
      var slug = row['share_slug'];
      if (row['owned'] == true) {
        slug = (await widget.repository!.action('share', {
          'post_id': row['id'],
        }))['slug'];
      }
      final base = config['public_base_url'] as String? ?? '';
      if (base.isNotEmpty && slug != null) {
        link = '${base.replaceAll(RegExp(r"/+$"), "")}/p/$slug';
      }
    } catch (_) {}
    final text =
        '${getPostDisplayTitle(row)}\n${link.isEmpty ? row['body'] : link}\n${app.text('文殊计数器 · 红书', 'Manjushri Counter · Hongshu')}';
    try {
      await const MethodChannel(
        'org.huideng.counter/notes',
      ).invokeMethod<void>('shareText', text);
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(app.text('内容已复制，可粘贴分享', 'Copied for sharing')),
          ),
        );
      }
    }
  }

  Future<void> openAttachment(Map file) async {
    try {
      if ((file['name'] as String? ?? '').toLowerCase().endsWith('.apk')) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(app.text('APK 文件', 'APK file')),
            content: Text(
              app.text(
                '安装第三方APK存在安全风险，请确认来源可信后再安装。',
                'Third-party APKs may be unsafe. Only install files from trusted sources.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(app.text('取消', 'Cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(app.text('下载', 'Download')),
              ),
            ],
          ),
        );
        if (accepted != true) return;
      }
      final remote = widget.repository?.remote;
      if (remote == null) throw StateError('offline');
      final String url;
      if (row['access_level'] == 'link_only' && row['owned'] != true) {
        final response = await remote.client.functions.invoke(
          'shared-page',
          body: {'slug': row['share_slug']},
        );
        final match = (response.data['post']['attachments'] as List)
            .where((a) => a['id'] == file['id'])
            .firstOrNull;
        if (match?['url'] == null) throw StateError('unavailable');
        url = match['url'];
      } else {
        url = await remote.client.storage
            .from('forum-files')
            .createSignedUrl(file['path'] as String, 120);
      }
      if (!await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('open_failed');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = app.text(
            '无法打开附件，请联网重试。',
            'Cannot open attachment. Check connection and retry.',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pictures = forumImages(row);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: row['author_user_id'] == null
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PublicProfilePage(
                            app: app,
                            userId: row['author_user_id'],
                          ),
                        ),
                      ),
                child: Row(
                  children: [
                    forumAuthorAvatar(app, row, radius: 18),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        row['author_name'] as String? ??
                            app.text('帖子详情', 'Post'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (social == true && !ownPost && row['author_user_id'] != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: following
                    ? OutlinedButton(
                        key: const ValueKey('forum-follow-button'),
                        onPressed: followBusy ? null : toggleFollow,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(app.text('已关注', 'Following')),
                      )
                    : FilledButton(
                        key: const ValueKey('forum-follow-button'),
                        onPressed: followBusy ? null : toggleFollow,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(app.text('关注', 'Follow')),
                      ),
              ),
          ],
        ),
        actions: [
          if (canManage)
            PopupMenuButton<String>(
              tooltip: '管理文章',
              enabled: !busy,
              onSelected: managePost,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑文章')),
                PopupMenuItem(value: 'delete', child: Text('删除文章')),
              ],
            ),
          IconButton(
            tooltip: app.text('分享', 'Share'),
            onPressed: available ? shareOptions : null,
            icon: const Icon(Icons.ios_share_outlined),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed:
                      busy ||
                          !available ||
                          row['is_locked'] == true ||
                          row['comments_closed'] == true
                      ? null
                      : reply,
                  icon: const Icon(Icons.reply),
                  label: Text(app.text('说点什么…', 'Reply…')),
                ),
              ),
              IconButton(
                tooltip: app.text('点赞', 'Like'),
                onPressed: busy || !available ? null : () => react('like'),
                icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
              ),
              Text(forumCount(count('like_count'))),
              IconButton(
                tooltip: app.text('收藏', 'Bookmark'),
                onPressed: busy || !available ? null : () => react('bookmark'),
                icon: Icon(bookmarked ? Icons.star : Icons.star_border),
              ),
              if (social == true) Text(forumCount(count('bookmark_count'))),
              IconButton(
                tooltip: app.text('回复', 'Reply'),
                onPressed:
                    busy ||
                        !available ||
                        row['is_locked'] == true ||
                        row['comments_closed'] == true
                    ? null
                    : reply,
                icon: const Icon(Icons.chat_bubble_outline),
              ),
              Text(forumCount(count('reply_count'))),
            ],
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: readingPageMaxWidth(760)),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (widget.siblings == null) return false;
              if (n is OverscrollNotification) trackOverscroll(n.overscroll);
              if (n is ScrollEndNotification) overscroll = 0;
              return false;
            },
            child: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (pictures.isNotEmpty) ...[
                SizedBox(
                  height: (MediaQuery.sizeOf(context).width * 1.12).clamp(
                    240.0,
                    520.0,
                  ),
                  child: PageView(
                    children: [
                      for (var i = 0; i < pictures.length; i++)
                        GestureDetector(
                          key: ValueKey('forum-detail-image-$i'),
                          onTap: () => openForumImages(context, pictures, i),
                          child: RoutedImage(
                            pictures[i],
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    pictures.length > 1
                        ? app.text(
                            '左右滑动查看 · 点击图片全屏',
                            'Swipe to browse · tap for full screen',
                          )
                        : app.text('点击图片全屏查看', 'Tap for full screen'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null) ...[
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      TextButton(
                        onPressed: refresh,
                        child: Text(app.text('重试', 'Retry')),
                      ),
                    ],
                    Text(
                      '${forumSectionName(app, row['category_id'])} · ${DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal().toString().substring(0, 16) ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((row['content_revision'] as num? ?? 0) > 0)
                      Text('已编辑 · ${row['updated_at'] ?? ''}'),
                    if (cached)
                      Text(app.text('正在查看离线缓存', 'Viewing offline cache')),
                    if (row['jieyuan'] is Map)
                      JieyuanActions(app: app, post: row),
                    if (row['jieyuan'] is Map)
                      Text(
                        jieyuanSummary(row['jieyuan']),
                        style: const TextStyle(color: Colors.amber),
                      ),
                    if (getPostDisplayTitle(row).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        getPostDisplayTitle(row),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                    ],
                    row['rich_body'] is List
                        ? RichContentView(
                            body: row['rich_body'] is List
                                ? jsonEncode(row['rich_body'])
                                : row['body'] as String? ?? '',
                          )
                        : WindowsContentText(child: SelectableText(
                            row['body'] as String? ?? '',
                            style: const TextStyle(fontSize: 18, height: 1.7),
                          )),
                    for (final file in row['attachments'] as List? ?? [])
                      if (file['kind'] != 'image')
                        ListTile(
                          leading: const Icon(Icons.attach_file),
                          title: Text(file['name'] as String),
                          subtitle: Text(
                            '${((file['size'] as num? ?? 0) / 1024).toStringAsFixed(1)} KB',
                          ),
                          onTap: () => openAttachment(file as Map),
                        ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final tag
                            in (row['tags'] as List? ?? []).whereType<String>())
                          Chip(label: Text('#$tag')),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Wrap(
                        key: const ValueKey('forum-post-stats'),
                        spacing: 18,
                        children: [
                          Text('♡ ${forumCount(count('like_count'))}'),
                          if (social == true)
                            Text('☆ ${forumCount(count('bookmark_count'))}'),
                          Text('💬 ${forumCount(count('reply_count'))}'),
                          if (social == true)
                            Text('阅读 ${forumCount(count('view_count'))}'),
                        ],
                      ),
                    ),
                    const Divider(),
                    if (social == true)
                      ForumComments(
                        key: commentsKey,
                        app: app,
                        social: socialApi!,
                        postId: row['id'] as String,
                        slug: row['share_slug'] as String?,
                        enabled:
                            available &&
                            row['is_locked'] != true &&
                            row['comments_closed'] != true,
                        onCount: (n) {
                          if (mounted) setState(() => stats['reply_count'] = n);
                        },
                      )
                    else ...[
                    Text(
                      app.text('最新回复（最多100条）', 'Latest replies (up to 100)'),
                    ),
                    if (replies.isEmpty)
                      Text(app.text('暂无回复', 'No replies yet')),
                    for (final item in replies)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: InkWell(
                          onTap: () => openForumAuthor(context, app, {
                            'author_user_id': item['user_id'],
                          }),
                          child: forumAuthorAvatar(app, {
                            'author_user_id': item['user_id'],
                          }, radius: 18),
                        ),
                        title: Text(item['author_name'] as String),
                        subtitle: Text(item['body'] as String),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
            ),
        ),
      ),
    );
  }
}
