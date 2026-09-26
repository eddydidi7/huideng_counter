import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/chat_store.dart';
import '../data/remote/chat_remote.dart';
import '../data/repositories/chat_repository.dart';
import '../services/attachment_service.dart';
import 'chat_room_page.dart';

Future<void> openGroupChat(
  BuildContext context,
  AppController app,
  String id,
) async {
  try {
    final client = app.cloud!.client!;
    final user = client.auth.currentUser!.id;
    final repo = ChatRepository(
      await ChatStore.open(user),
      ChatRemote(client, user),
    );
    final rooms = await repo.rooms();
    repo.remote.checkUser();
    final room = rooms.where((r) => r['id'] == id).firstOrNull;
    if (room == null) throw StateError('当前没有该群访问权限');
    if (context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatRoomPage(app: app, repository: repo, room: room),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> chooseMyGroup(BuildContext context, AppController app) async {
  try {
    final rows =
        await AttachmentService(app.cloud!.client!).group('my_groups', {})
            as List;
    if (!context.mounted) return;
    final r = await showModalBottomSheet<Map>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            for (final r in rows)
              ListTile(
                title: Text(r['title']),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (r != null && context.mounted) {
      // “我的群组” is a chat entry point. Group files, notices and practice
      // features remain reachable from the room's own information page.
      await openGroupChat(context, app, r['id'] as String);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
