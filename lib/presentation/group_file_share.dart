import 'package:flutter/material.dart';
import '../services/attachment_service.dart';

Future<void> publishGroupFile(
  BuildContext context,
  AttachmentService files,
  Map<String, dynamic> file,
) async {
  try {
    files.guard();
    final result = await files.client.rpc(
      'group_resource_v1',
      params: {'p_action': 'categories'},
    );
    files.guard();
    if (!context.mounted) return;
    final categories = (result as List).cast<String>();
    String? chosen = categories.firstOrNull;
    final category = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('转存到公共网盘'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('转存后所有人都可以查看和下载这份文件。'),
              DropdownButton<String>(
                isExpanded: true,
                value: chosen,
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => update(() => chosen = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: chosen == null
                  ? null
                  : () => Navigator.pop(ctx, chosen),
              child: const Text('公开转存'),
            ),
          ],
        ),
      ),
    );
    if (category == null || !context.mounted) return;
    await files.verifyGroup(file['file_id'] as String);
    files.guard();
    await files.client.rpc(
      'group_resource_v1',
      params: {
        'p_action': 'publish',
        'p_data': {'file_id': file['file_id'], 'category': category},
      },
    );
    files.guard();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已转存到公共网盘')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('转存未完成，请检查权限或稍后重试')));
    }
  }
}
