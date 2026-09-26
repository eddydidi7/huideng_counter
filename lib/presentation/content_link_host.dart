import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import 'notes_page.dart';
import 'note_reader_page.dart';
import 'large_note_editor.dart';
import '../services/group_practice_sync.dart';
import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/home_message_cache.dart';
import '../data/remote/forum_remote.dart';
import '../data/repositories/forum_repository.dart';
import 'forum_page.dart';
import 'cloud_drive_page.dart';
import 'settings_page.dart';
import 'app_update_page.dart';
import '../services/chat_notifications.dart';
import '../services/solar_reminder_service.dart';
import '../data/local/chat_store.dart';
import '../data/remote/chat_remote.dart';
import '../data/repositories/chat_repository.dart';
import 'chat_room_page.dart';

class ContentLinkHost extends StatefulWidget {
  const ContentLinkHost({
    super.key,
    required this.app,
    required this.navigatorKey,
    required this.child,
  });
  final AppController app;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  State<ContentLinkHost> createState() => _ContentLinkHostState();
}

class _ContentLinkHostState extends State<ContentLinkHost> {
  StreamSubscription<Uri>? subscription;
  Uri? pending;
  Timer? retry;
  Timer? practiceRetry;
  String? last;
  ChatNotifications? chatNotifications;
  bool openingNotification = false;
  void syncNotifications() {
    final client = widget.app.cloud?.client;
    final user = client?.auth.currentUser?.id;
    if (chatNotifications?.user != user) {
      chatNotifications?.dispose();
      chatNotifications = client != null && user != null
          ? (ChatNotifications(client, user)..start())
          : null;
    }
    openNotification();
  }

  Future<void> openNotification() async {
    final payload = SolarReminderService.tappedPayload.value;
    final client = widget.app.cloud?.client,
        nav = widget.navigatorKey.currentState;
    final user = client?.auth.currentUser?.id;
    if (payload == null ||
        client == null ||
        user == null ||
        nav == null ||
        openingNotification) {
      return;
    }
    final parts = payload.split(':');
    if (parts.first != 'chat' || (parts.length != 2 && parts.length != 3)) {
      return;
    }
    SolarReminderService.tappedPayload.value = null;
    if (parts.length == 3 && parts[1] != user) return;
    openingNotification = true;
    try {
      final remote = ChatRemote(client, user);
      final rooms = await remote.call('rooms') as List;
      final room = rooms.where((r) => r['id'] == parts.last).firstOrNull;
      if (room == null || !mounted) return;
      final repo = ChatRepository(await ChatStore.open(user), remote);
      if (!mounted) return;
      await nav.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatRoomPage(
            app: widget.app,
            repository: repo,
            room: Map<String, dynamic>.from(room),
          ),
        ),
      );
    } catch (_) {
      /* Membership can change after a notification is delivered. */
    } finally {
      openingNotification = false;
    }
  }

  @override
  void initState() {
    super.initState();
    initializeLinks();
    practiceRetry = Timer.periodic(
      const Duration(seconds: 15),
      (_) => GroupPracticeSync.flush(widget.app),
    );
    retry = Timer.periodic(const Duration(seconds: 1), (_) {
      open();
      syncNotifications();
    });
  }

  Future<void> initializeLinks() async {
    try {
      final links = AppLinks();
      final initial = await links.getInitialLink();
      if (!mounted) return;
      subscription = links.uriLinkStream.listen(receive, onError: (_) {});
      if (initial != null) receive(initial);
    } catch (_) {
      /* Platforms without an incoming-link implementation retain in-app navigation. */
    }
  }

  void receive(Uri u) {
    if (u.scheme != 'huideng' ||
        ![
          'forum',
          'resource',
          'note',
          'shared-note',
          'update',
        ].contains(u.host)) {
      return;
    }
    if (last == u.toString()) return;
    pending = u;
    open();
  }

  void open() {
    final u = pending,
        client = widget.app.cloud?.client,
        nav = widget.navigatorKey.currentState;
    if (!mounted || u == null || nav == null) return;
    if (u.host == 'update') {
      pending = null;
      last = u.toString();
      nav.push(
        MaterialPageRoute<void>(builder: (_) => AppUpdatePage(app: widget.app)),
      );
      return;
    }
    if (u.host == 'note' &&
        u.pathSegments.length == 1 &&
        RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(u.pathSegments.single)) {
      pending = null;
      final repo = widget.app.repository;
      if (repo is SqliteCounterRepository) {
        final notes = NotesRepository(repo.db);
        notes
            .get(u.pathSegments.single)
            .then((note) {
              if (!mounted || !identical(repo, widget.app.repository)) return;
              nav.push(
                MaterialPageRoute(
                  builder: (_) => (note['body'] as String).length > 100000
                      ? LargeNoteEditor(
                          app: widget.app,
                          repository: notes,
                          note: note,
                        )
                      : NoteEditor(
                          app: widget.app,
                          repository: notes,
                          note: note,
                        ),
                ),
              );
            })
            .catchError((Object e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('当前账号中没有这篇笔记，请先同步或确认账号。')),
                );
              }
            });
      }
      return;
    }
    if (client == null) return;
    Widget? page;
    if (u.host == 'shared-note' &&
        u.pathSegments.length == 1 &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(u.pathSegments.single)) {
      final data = client.rpc(
        'shared_page_v1',
        params: {'p_slug': u.pathSegments.single},
      );
      page = Scaffold(
        body: SafeArea(
          child: FutureBuilder(
            future: data,
            builder: (context, result) {
              final data = result.data;
              final post = data is Map ? data['post'] : null;
              if (result.hasError ||
                  (result.connectionState == ConnectionState.done &&
                      post is! Map)) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('链接已失效或暂时无法访问。'),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                );
              }
              if (!result.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (post is! Map) {
                return const Center(child: CircularProgressIndicator());
              }
              return NoteReaderPage(
                storedNote: false,
                app: widget.app,
                body: post['body'] as String? ?? '',
                title: post['title'] as String? ?? '',
                noteId: 'shared-${u.pathSegments.single}',
                scope: widget.app.scopeId,
              );
            },
          ),
        ),
      );
    }
    if (u.host == 'forum' &&
        u.pathSegments.length == 2 &&
        u.pathSegments[0] == 'post' &&
        RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(u.pathSegments[1])) {
      page = ForumDetailPage(
        app: widget.app,
        row: {'id': u.pathSegments[1], 'share_slug': u.queryParameters['slug']},
        repository: ForumRepository(
          ForumRemote(client),
          HomeMessageCache(cacheKey: 'forum_feed'),
        ),
      );
    }
    if (u.host == 'resource' &&
        u.pathSegments.length == 1 &&
        RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(u.pathSegments[0])) {
      page = CloudDrivePage(
        app: widget.app,
        settingsPage: SettingsPage(app: widget.app),
        initialResourceId: u.pathSegments[0],
      );
    }
    pending = null;
    if (page != null) {
      last = u.toString();
      final destination = page;
      nav.push(MaterialPageRoute(builder: (_) => destination)).then((_) {
        last = null;
      });
    }
  }

  @override
  void dispose() {
    chatNotifications?.dispose();
    subscription?.cancel();
    retry?.cancel();
    practiceRetry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
