import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import '../data/local/home_message_cache.dart';
import 'forum_page.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../domain/public_resource.dart';
import '../domain/content_share.dart';
import '../services/content_transfer.dart';
import '../services/attachment_service.dart';
import 'forum_chat_share.dart';
import 'forum_compose_page.dart';
import 'cloud_drive_page.dart';
import 'settings_page.dart';

Future<void> shareResource(
  BuildContext context,
  AppController app,
  PublicResource file,
) async {
  final choice = await showModalBottomSheet<ShareTarget>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in {
            ShareTarget.chat: '分享到聊天',
            ShareTarget.redbook: '发布到红书',
            ShareTarget.note: '引用到笔记',
            ShareTarget.personalDrive: '收藏到个人资料夹（保留引用）',
          }.entries)
            ListTile(
              title: Text(e.value),
              onTap: () => Navigator.pop(ctx, e.key),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final ref = ContentReference(
    type: 'resource',
    id: file.id,
    title: file.name,
    summary: file.description,
  );
  final text =
      '${file.name}\n${(file.size / 1048576).toStringAsFixed(1)} MB · 文殊资料库\n${file.description}\n${ref.link}';
  try {
    switch (choice) {
      case ShareTarget.chat:
        await shareTextToChat(context, app, text);
        break;
      case ShareTarget.redbook:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ForumComposePage(
              app: app,
              repository: ForumRepository(
                ForumRemote(app.cloud!.client!),
                HomeMessageCache(cacheKey: 'forum_feed'),
              ),
              categories: forumCategories,
              initialCategory: 'resources',
              initialTitle: file.name,
              initialBody: text,
            ),
          ),
        );
        break;
      case ShareTarget.note:
        await ContentTransfer(app).notes.save({
          'title': file.name,
          'body': text,
          'source_meta': jsonEncode({'type': 'resource', 'id': file.id}),
        });
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已引用到私人笔记')));
        }
        break;
      case ShareTarget.personalDrive:
        await AttachmentService(app.cloud!.client!).group('save_reference', {
          'kind': 'resource',
          'source_id': file.id,
          'title': file.name,
          'metadata': {'size': file.size, 'description': file.description},
        });
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已保存引用；原资料访问权限继续有效')));
        }
        break;
      default:
        break;
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

String? sharedResourceId(String text) => RegExp(
  r'huideng://resource/([a-zA-Z0-9_-]{1,100})(?![a-zA-Z0-9_-])',
).firstMatch(text)?.group(1);

class ResourceShareCard extends StatelessWidget {
  const ResourceShareCard({super.key, required this.app, required this.text});
  final AppController app;
  final String text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.description_outlined),
      Text(text.split('\n').first, style: const TextStyle(fontSize: 18)),
      const Text('文殊资料库'),
      TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CloudDrivePage(
              app: app,
              settingsPage: SettingsPage(app: app),
              initialResourceId: sharedResourceId(text),
            ),
          ),
        ),
        child: const Text('打开资料'),
      ),
    ],
  );
}
