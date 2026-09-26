import 'tibetan_calendar_page.dart';
import 'account_panel.dart';
import 'app_update_page.dart';
import 'chat_page.dart';
import 'forum_page.dart';
import 'public_profile_page.dart';
import 'settings_page.dart';
import 'routed_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import 'backup_page.dart';
import 'notes_page.dart';
import 'notices_page.dart';
import 'shared.dart';
import 'cloud_drive_page.dart';
import 'activity_links_page.dart';

class SettingsServicesPage extends StatelessWidget {
  final AppController app;
  const SettingsServicesPage({super.key, required this.app});

  void open(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(app.text('常用', 'Common'))),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ListTile(
              leading: const Icon(Icons.system_update),
              title: Text(app.text('更新版本', 'Update version')),
              onTap: () => open(context, AppUpdatePage(app: app)),
            ),
            ListTile(
              key: const ValueKey('common-account-sync'),
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(app.text('账号与同步', 'Account and sync')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(context, AccountSyncPage(app: app)),
            ),
            ListTile(
              key: const ValueKey('common-personal-profile'),
              leading: const Icon(Icons.person_outline),
              title: Text(app.text('个人主页', 'Personal profile')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final user = app.cloud?.client?.auth.currentUser;
                open(
                  context,
                  user == null
                      ? SettingsPage(app: app)
                      : PublicProfilePage(app: app, userId: user.id),
                );
              },
            ),
            Card(
              key: const ValueKey('my-offering-panel'),
              child: ListTile(
                leading: const Icon(Icons.local_florist_outlined),
                title: Text(app.text('供佛 / 供灯', 'Buddha / lamp offerings')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final url = app.offeringUrl;
                  if (url == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          app.text(
                            '供佛链接尚未设置',
                            'Offering link is not configured',
                          ),
                        ),
                      ),
                    );
                    return;
                  }
                  try {
                    bool opened;
                    try {
                      opened = await launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.inAppBrowserView,
                      );
                    } catch (_) {
                      opened = false;
                    }
                    if (!opened) {
                      opened = await launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      );
                    }
                    if (!opened && context.mounted) {
                      throw StateError('unavailable');
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            app.text(
                              '无法打开供佛链接，请稍后重试',
                              'Unable to open the offering website',
                            ),
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              key: const ValueKey('my-practice-panel'),
              leading: const Icon(Icons.groups_outlined),
              title: Text(app.text('通知', 'Notifications')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(context, NoticesPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(app.text('公共网盘', 'Public cloud drive')),
              subtitle: Text(
                app.text('公共资源 · 共享下载', 'Shared resources · Downloads'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(
                context,
                CloudDrivePage(
                  app: app,
                  settingsPage: StorageStatusPage(app: app),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(app.text('共修', 'Group practice')),
              onTap: () => open(context, ActivityLinksPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_month),
              title: Text(app.text('藏历 / 日出', 'Calendar / Sunrise')),
              onTap: () => open(context, TibetanCalendarPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.note_outlined),
              title: Text(app.text('笔记', 'Notes')),
              onTap: () => open(context, NotesPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: Text(app.text('聊天', 'Chat')),
              onTap: () => open(context, ChatPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(app.text('红书', 'Hongshu')),
              onTap: () => open(context, ForumPage(app: app)),
            ),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text(app.text('商城', 'Shop')),
              onTap: () =>
                  open(context, ForumPage(app: app, category: 'jieyuan')),
            ),
            ListTile(
              key: const ValueKey('common-forum-bookmarks'),
              leading: const Icon(Icons.bookmarks_outlined),
              title: Text(app.text('红书收藏', 'Saved Hongshu posts')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  open(context, ForumPage(app: app, initialSort: 'bookmarks')),
            ),
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: Text(app.text('收藏', 'Favorites')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(
                context,
                NotesPage(app: app, initialFolder: 'favorites'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class StorageStatusPage extends StatelessWidget {
  final AppController app;
  const StorageStatusPage({super.key, required this.app});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(app.text('备份与存储设置', 'Backup and storage settings')),
    ),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ListTile(
          title: const Text('Supabase Storage'),
          subtitle: Text(
            app.text(
              '海外推荐 · 当前项目图片存储服务',
              'Recommended overseas · Current project image storage',
            ),
          ),
        ),
        Text(
          app.text(
            '计数和笔记通过账号同步。图片存储连接状态需登录后测试。',
            'Counts and notes sync with your account. Sign in to test image storage.',
          ),
        ),
        FilledButton.tonal(
          onPressed: app.cloud?.client?.auth.currentSession == null
              ? null
              : () async {
                  try {
                    final cloud = app.cloud!;
                    final owner = cloud.client!.auth.currentUser!.id;
                    await cloud.client!.storage
                        .from('counter-images')
                        .list(path: owner)
                        .timeout(const Duration(seconds: 15));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            app.text(
                              '存储连接测试成功',
                              'Storage connection successful',
                            ),
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showFailure(context, app, e);
                  }
                },
          child: Text(app.text('测试连接', 'Test connection')),
        ),
        for (final entry in [
          [
            '阿里云 OSS',
            'Alibaba Cloud OSS',
            '中国大陆推荐',
            'Recommended in mainland China',
          ],
          [
            '腾讯云 COS',
            'Tencent Cloud COS',
            '中国大陆推荐',
            'Recommended in mainland China',
          ],
          ['Google Drive', 'Google Drive', '个人备份', 'Personal backup'],
        ])
          ListTile(
            title: Text(app.text(entry[0], entry[1])),
            subtitle: Text(
              '${app.text(entry[2], entry[3])} · ${app.text('未连接', 'Not connected')}',
            ),
          ),
        Text(
          app.text(
            '其他存储服务尚未接入，暂不能切换或云端恢复。现有云端数据保持原样。',
            'Other providers are not integrated yet; switching and cloud restoration are unavailable. Existing cloud data is retained.',
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: Text(app.text('本地备份与恢复', 'Local backup and restore')),
          subtitle: Text(
            app.text(
              'CSV 计数导出 / JSON 完整备份',
              'CSV count export / full JSON backup',
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => BackupPage(app: app)),
          ),
        ),
      ],
    ),
  );
}

class AboutPage extends StatelessWidget {
  final AppController app;
  const AboutPage({super.key, required this.app});
  Future<void> copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(app.text('已复制', 'Copied'))));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(app.text('关于与联系', 'About and contact'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            app.text('文殊计数器', 'Manjushri Counter'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if ((app.aboutContent[app.english ? 'text_en' : 'text_zh']
                      as String? ??
                  '')
              .isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: SelectableText(
                app.aboutContent[app.english ? 'text_en' : 'text_zh'] as String,
              ),
            ),
          for (final image
              in (app.aboutContent['images'] as List? ?? [])
                  .whereType<String>())
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: RoutedImage(
                image,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    Text(app.text('图片暂时无法加载', 'Image unavailable')),
              ),
            ),
          Text(app.text('版本 1.0.32（33）', 'Version 1.0.32 (33)')),
          ListTile(
            title: Text(app.aboutContent['email'] as String? ?? ''),
            subtitle: Text(app.text('邮箱', 'Email')),
            trailing: IconButton(
              tooltip: app.text('复制邮箱', 'Copy email'),
              icon: const Icon(Icons.copy),
              onPressed: () =>
                  copy(context, app.aboutContent['email'] as String? ?? ''),
            ),
            onTap: () async {
              try {
                if (!await launchUrl(
                  Uri(
                    scheme: 'mailto',
                    path: app.aboutContent['email'] as String? ?? '',
                  ),
                )) {
                  throw StateError('mail_unavailable');
                }
              } catch (e) {
                if (context.mounted) showFailure(context, app, e);
              }
            },
          ),
          ListTile(
            title: Text(app.aboutContent['qq'] as String? ?? ''),
            subtitle: const Text('QQ'),
            trailing: IconButton(
              tooltip: app.text('复制 QQ', 'Copy QQ'),
              icon: const Icon(Icons.copy),
              onPressed: () =>
                  copy(context, app.aboutContent['qq'] as String? ?? ''),
            ),
          ),
        ],
      ),
    ),
  );
}
