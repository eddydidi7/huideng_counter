import 'package:flutter/material.dart';
import 'app_update_page.dart';
import '../core/app_controller.dart';
import 'group_navigation.dart';
import 'group_practice_page.dart';

class NoticesPage extends StatelessWidget {
  final AppController app;
  final bool embedded;
  final bool compactHeader;
  final bool practiceOnly;
  const NoticesPage({
    super.key,
    required this.app,
    this.embedded = false,
    this.compactHeader = false,
    this.practiceOnly = false,
  });
  String content(Map<String, dynamic> row, String field) =>
      row['${field}_${app.english ? 'en' : 'zh'}'] as String? ?? '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([app, app.notices]),
    builder: (_, _) {
      final items = (app.notices?.items ?? <Map<String, dynamic>>[])
          .where((row) => !practiceOnly || row['notice_type'] == 'practice')
          .toList();
      final header = AppBar(
        primary: !embedded,
        toolbarHeight: embedded ? 36 : null,
        titleSpacing: embedded ? 12 : null,
        title: Text(
          practiceOnly
              ? app.text('共修', 'Group practice')
              : app.text('通知', 'Notifications'),
          style: compactHeader
              ? Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) *
                      0.6,
                )
              : null,
        ),
        automaticallyImplyLeading: !embedded,
        actions: [
          if (practiceOnly && !embedded)
            IconButton(
              tooltip: app.text('我的群共修', 'My group practices'),
              icon: const Icon(Icons.groups_outlined),
              onPressed: () => choosePracticeGroup(context, app),
            ),
          if (embedded)
            TextButton(
              style: embedded
                  ? TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(64, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )
                  : null,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      NoticesPage(app: app, practiceOnly: practiceOnly),
                ),
              ),
              child: Text(
                app.text('查看全部', 'View all'),
                style: TextStyle(
                  fontSize:
                      (Theme.of(context).textTheme.labelLarge?.fontSize ?? 14) *
                      0.95,
                ),
              ),
            ),
        ],
      );
      final contentBody = Center(
        heightFactor: embedded ? 1 : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: RefreshIndicator(
            onRefresh: () async {
              await app.notices?.refresh();
            },
            child: ListView(
              shrinkWrap: embedded,
              padding: EdgeInsets.all(embedded ? 2 : 20),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (!embedded)
                  Text(
                    app.text(
                      practiceOnly
                          ? '显示后台发布的共修通知；可下拉刷新，离线时显示缓存内容。'
                          : '显示最近发布的通知及置顶内容；可下拉刷新。离线时显示已缓存内容。',
                      practiceOnly
                          ? 'Published group practice notices. Pull to refresh; cached content is available offline.'
                          : 'Recent and pinned notices. Pull to refresh. Cached content is available offline.',
                    ),
                  ),
                if (items.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(embedded ? 8 : 32),
                    child: Text(
                      app.text(
                        '暂无可显示的通知，请联网后下拉刷新。',
                        'No notices available. Connect and pull to refresh.',
                      ),
                    ),
                  ),
                for (final row in items)
                  Card(
                    margin: embedded
                        ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
                        : null,
                    child: ListTile(
                      dense: embedded,
                      contentPadding: embedded
                          ? const EdgeInsets.symmetric(horizontal: 8)
                          : null,
                      minVerticalPadding: embedded ? 2 : null,
                      minLeadingWidth: embedded ? 20 : null,
                      horizontalTitleGap: embedded ? 8 : null,
                      leading: row['is_pinned'] == true
                          ? const Icon(Icons.push_pin_outlined)
                          : const Icon(Icons.article_outlined),
                      title: Text(content(row, 'title')),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            content(row, 'body'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            (DateTime.tryParse(
                                      row['published_at'] as String? ?? '',
                                    )?.toLocal().toString() ??
                                    '')
                                .split('.')
                                .first,
                          ),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => row['release_version_code'] != null
                              ? AppUpdatePage(app: app)
                              : Scaffold(
                            appBar: AppBar(title: Text(content(row, 'title'))),
                            body: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 760,
                                ),
                                child: ListView(
                                  padding: const EdgeInsets.all(24),
                                  children: [
                                    if (row['release_version_code'] != null)
                                      FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AppUpdatePage(app: app))), child: const Text('查看更新')),
                                    if (row['group_id'] is String &&
                                        app.cloud?.client?.auth.currentUser !=
                                            null)
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton.icon(
                                            icon: const Icon(
                                              Icons.groups_outlined,
                                            ),
                                            label: Text(
                                              app.text(
                                                '进入共修群',
                                                'Open practice group',
                                              ),
                                            ),
                                            onPressed: () => openGroupChat(
                                              context,
                                              app,
                                              row['group_id'] as String,
                                            ),
                                          ),
                                          TextButton.icon(
                                            icon: const Icon(
                                              Icons.add_circle_outline,
                                            ),
                                            label: Text(
                                              app.text(
                                                '参与群共修',
                                                'Group practice',
                                              ),
                                            ),
                                            onPressed: () => Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    GroupPracticePage(
                                                      app: app,
                                                      groupId:
                                                          row['group_id']
                                                              as String,
                                                      title: content(
                                                        row,
                                                        'title',
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    SelectableText(
                                      content(row, 'body'),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyLarge,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (embedded) {
        // A nested Scaffold/AppBar used to reserve the status bar a second time.
        // Let short/empty content shrink, while a long feed scrolls independently.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 36, child: header),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.textScalerOf(
                  context,
                ).scale(120).clamp(120, 180),
              ),
              child: contentBody,
            ),
          ],
        );
      }
      return Scaffold(appBar: header, body: contentBody);
    },
  );
}
