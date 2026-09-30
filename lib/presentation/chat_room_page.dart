import 'group_invite_page.dart';
import 'group_admin_page.dart';
import '../data/remote/group_admin.dart';
import '../services/group_operation_error.dart';
import '../services/chat_notifications.dart';
import '../services/resource_upload_policy.dart';
import '../services/apk_files.dart';
import '../services/chat_apk_storage.dart';
import 'apk_file_card.dart';
import '../services/attachment_service.dart';
import 'resource_share.dart';
import 'group_learning_page.dart';
import 'chat_save_notes_page.dart';
import 'routed_image.dart';
import 'chat_attachment_panel.dart';
import 'chat_info_page.dart';
import '../services/solar_reminder_service.dart';
import 'package:geolocator/geolocator.dart';
import 'chat_qr_page.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/repositories/chat_repository.dart';
import 'chat_page.dart';
import '../data/remote/chat_live.dart';
import 'direct_transfer_page.dart';
import 'package:open_filex/open_filex.dart';
import '../services/chat_image.dart';
import 'chat_gallery_page.dart';
import '../domain/chat_view.dart';
import 'chat_history_actions.dart';
import 'chat_avatar.dart';
import 'chat_voice_widgets.dart';
import 'voice_call_host.dart';
import 'chat_message_style.dart';
import 'chat_emoji_panel.dart';
import '../services/chat_sticker_store.dart';
import '../domain/forum_share.dart';
import 'forum_chat_share.dart';

/// Cosmetic highlight for any "@word" token in a message body. Precise
/// "who was actually mentioned" lives server-side in the message's
/// `mentions` user-id array (see [mentionsCurrentUser]); this only makes the
/// text visually stand out and never affects copy/forward/recall/reply.
Widget mentionAwareText(
  String body,
  TextStyle style, {
  required bool mentionsMe,
}) {
  final matches = RegExp(r'@[^\s@]{1,40}').allMatches(body).toList();
  if (matches.isEmpty) return Text(body, style: style);
  final highlight = style.copyWith(
    color: mentionsMe ? Colors.redAccent : Colors.blueAccent,
    fontWeight: FontWeight.w600,
  );
  final spans = <InlineSpan>[];
  var last = 0;
  for (final match in matches) {
    if (match.start > last)
      spans.add(TextSpan(text: body.substring(last, match.start)));
    spans.add(
      TextSpan(text: body.substring(match.start, match.end), style: highlight),
    );
    last = match.end;
  }
  if (last < body.length) spans.add(TextSpan(text: body.substring(last)));
  return Text.rich(TextSpan(style: style, children: spans));
}

bool mentionsCurrentUser(Map<String, dynamic> m, String userId) {
  if (m['mention_all'] == true) return true;
  final ids = m['mentions'];
  return ids is List && ids.contains(userId);
}

/// Bottom sheet to pick one group member (or "所有人" for managers) to
/// mention. Paged/searchable via the same group_admin_v1 'members' action
/// GroupMembersPage uses, so a huge group never loads its whole roster.
class _MentionPicker extends StatefulWidget {
  const _MentionPicker({
    required this.app,
    required this.admin,
    required this.canMentionAll,
  });
  final AppController app;
  final GroupAdmin admin;
  final bool canMentionAll;
  @override
  State<_MentionPicker> createState() => _MentionPickerState();
}

class _MentionPickerState extends State<_MentionPicker> {
  final search = TextEditingController();
  List<Map<String, dynamic>> items = [];
  bool loading = false;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    load();
    search.addListener(() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), load);
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final page = await widget.admin.members(
        query: search.text.trim(),
        limit: 30,
      );
      if (mounted) setState(() => items = GroupAdmin.rows(page['items']));
    } catch (_) {
      /* Non-fatal: the picker just shows an empty list. */
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String name(Map<String, dynamic> m) =>
      (m['group_nickname'] as String?)?.isNotEmpty == true
      ? m['group_nickname'] as String
      : (m['nickname'] as String? ?? '学友');

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: search,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: '搜索群成员',
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (widget.canMentionAll && search.text.trim().isEmpty)
                  ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.campaign_outlined),
                    ),
                    title: const Text('所有人'),
                    onTap: () => Navigator.pop(context, {'all': true}),
                  ),
                for (final m in items)
                  ListTile(
                    leading: ChatAvatar(
                      app: widget.app,
                      groupId: widget.admin.roomId,
                      remote: null,
                      publicClient: widget.admin.client,
                      userId: m['user_id'] as String,
                      radius: 18,
                    ),
                    title: Text(
                      name(m),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('个人号：${m['personal_number'] ?? '未设置'}'),
                    onTap: () => Navigator.pop(context, {
                      'user_id': m['user_id'],
                      'name': name(m),
                    }),
                  ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class ChatRoomPage extends StatefulWidget {
  final AppController app;
  final ChatRepository repository;
  final Map<String, dynamic> room;
  final ChatLive? live;
  final String? initialSharedText;
  const ChatRoomPage({
    super.key,
    required this.app,
    required this.repository,
    required this.room,
    this.live,
    this.initialSharedText,
  });
  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  final attachmentUrls = <String, Future<String>>{};
  final scroll = ScrollController();
  List<Map<String, dynamic>> messages = [], pending = [], members = [];
  Timer? timer, debounce;
  final messageChanges = ValueNotifier<int>(0);
  RealtimeChannel? channel;
  StreamSubscription<AuthState>? auth;
  bool busy = false,
      sending = false,
      active = true,
      denied = false,
      pinned = false,
      muted = false;
  int failures = 0;
  String? error;
  String? clearedThrough;
  late String title;
  Timer? draftTimer;
  bool draftReady = false, allowLeave = false;
  bool voiceInput = false, attachmentsOpen = false;
  final composerFocus = FocusNode();
  int? backgroundColor;
  late final VoicePlaybackController voicePlayback;
  Future<void> draftWrites = Future.value();
  ChatRepository get repo => widget.repository;
  String get room => widget.room['id'] as String;
  String get user => repo.remote.userId;
  String tr(String a, String b) => widget.app.text(a, b);
  bool get owner => widget.room['owner_id'] == user;
  bool get group => widget.room['kind'] == 'group';
  // Group administration (migration 202609250072); absent on older servers.
  GroupAdmin? groupAdmin;
  String groupRole = 'member';
  bool groupReady = false;
  List<Map<String, dynamic>> groupPins = [];
  bool get groupManager => groupRole == 'owner' || groupRole == 'admin';

  // @mention tracking for the message currently being composed. Keyed by
  // user_id so a later nickname change can't confuse who was mentioned;
  // stale entries (the "@name " text got edited away) are dropped at send.
  final mentionIds = <String, String>{};
  bool mentionAll = false;
  bool _mentionSheetOpen = false;

  void insertAtCursor(String text) {
    final selection = input.selection;
    final cursor = selection.start >= 0 ? selection.start : input.text.length;
    final newText = input.text.replaceRange(cursor, cursor, text);
    input.value = input.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor + text.length),
    );
  }

  Future<void> openMentionPicker() async {
    final admin = groupAdmin ??= GroupAdmin(repo.remote.client, room);
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MentionPicker(
        app: widget.app,
        admin: admin,
        canMentionAll: groupManager,
      ),
    );
    if (picked == null || !mounted) return;
    if (picked['all'] == true) {
      mentionAll = true;
      insertAtCursor('@所有人 ');
    } else {
      final id = picked['user_id'] as String;
      final name = picked['name'] as String;
      mentionIds[id] = name;
      insertAtCursor('@$name ');
    }
  }

  void checkMentionTrigger() {
    if (!group || _mentionSheetOpen) return;
    final text = input.text;
    final cursor = input.selection.baseOffset;
    if (cursor < 1 || cursor > text.length || text[cursor - 1] != '@') return;
    _mentionSheetOpen = true;
    unawaited(
      openMentionPicker().whenComplete(() => _mentionSheetOpen = false),
    );
  }

  Future<void> loadGroupState({bool announce = false}) async {
    if (!group) return;
    final admin = groupAdmin ??= GroupAdmin(repo.remote.client, room);
    try {
      final overview = await admin.overview();
      final pins = await admin.pins();
      if (!mounted) return;
      setState(() {
        groupRole = overview['my_role'] as String? ?? 'member';
        groupPins = pins;
        groupReady = true;
      });
      if (announce && mounted) await showGroupAnnouncementPopup(context, admin);
    } catch (_) {
      // Server not upgraded yet: the chat keeps working as before.
    }
  }

  /// Large groups: managers plus the newest 100 members, never the whole
  /// roster on every refresh. Older servers fall back to the full list.
  Future<List<Map<String, dynamic>>> groupRoster() async {
    try {
      final page = await (groupAdmin ??= GroupAdmin(
        repo.remote.client,
        room,
      )).members(limit: 100);
      return [
        ...GroupAdmin.rows(page['managers']),
        ...GroupAdmin.rows(page['items']),
      ];
    } catch (_) {
      return ChatRepository.rows(
        await repo.remote.call('members', {'room_id': room}),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    voicePlayback = VoicePlaybackController(repo);
    title = widget.room['title'] as String;
    ChatNotifications.visibleRoom = widget.room['id'] as String;
    pinned = widget.room['pinned'] == true;
    muted = widget.room['muted'] == true;
    WidgetsBinding.instance.addObserver(this);
    input.addListener(() {
      if (mounted) setState(() {});
      checkMentionTrigger();
      if (!draftReady) return;
      draftTimer?.cancel();
      draftTimer = Timer(
        const Duration(milliseconds: 400),
        () => unawaited(saveDraft().catchError(draftError)),
      );
    });
    auth = repo.remote.client.auth.onAuthStateChange.listen((_) {
      if (repo.remote.client.auth.currentUser?.id != user && mounted) {
        setState(() {
          denied = true;
          messages = [];
          pending = [];
          members = [];
        });
        timer?.cancel();
      }
    });
    channel = repo.remote.client
        .channel('room:$room:$user')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: room,
          ),
          callback: (_) {
            debounce?.cancel();
            debounce = Timer(
              const Duration(milliseconds: 300),
              () => refresh(),
            );
          },
        )
        .subscribe();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final cached = await repo.store.read('messages:$room');
      final view = await repo.store.roomViews();
      if (!mounted || denied) return;
      if (input.text.isEmpty) {
        input.text = view[room]?['draft'] as String? ?? '';
        if (widget.initialSharedText != null) {
          input.text = [
            if (input.text.isNotEmpty) input.text,
            widget.initialSharedText!,
          ].join('\n');
        }
      }
      draftReady = true;
      if (widget.initialSharedText != null) await saveDraft();
      clearedThrough = view[room]?['clearedThrough'] as String?;
      backgroundColor = view[room]?['backgroundColor'] as int?;
      setState(() => messages = cached);
      await refresh();
      if (group) unawaited(loadGroupState(announce: true));
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    }
  }

  List<Map<String, dynamic>> callHistory = [];

  Future<void> retryFailedApks() async {
    for (final item in await repo.store.pending()) {
      if (item['room_id'] == room &&
          item['last_error'] == 'APK_RETRY_REQUIRED') {
        await repo.store.failed(item['id'] as String, null);
      }
    }
    await refresh();
  }

  Future<void> refresh() async {
    if (!mounted || busy || !active || denied) return;
    busy = true;
    try {
      final queued = await repo.store.pending();
      if (!mounted) return;
      setState(
        () => pending = queued.where((e) => e['room_id'] == room).toList(),
      );
      // A blocked/rejected outbox item must not prevent receiving messages.
      Object? sendError;
      try {
        await repo.flush();
      } catch (e) {
        sendError = e;
      }
      final value = await repo.messages(room);
      final liveIds = await repo.existingMessages(
        room,
        messages.map((m) => m['id'] as String),
      );
      final roster = group
          ? (members.isNotEmpty ? members : await groupRoster())
          : ChatRepository.rows(
              await repo.remote.call('members', {'room_id': room}),
            );
      final currentRooms = await repo.rooms();
      final currentRoom = currentRooms
          .where((r) => r['id'] == room)
          .firstOrNull;
      if (!group) {
        try {
          final calls = await repo.remote.client
              .from('chat_calls')
              .select('id,caller_id,state,created_at,accepted_at,ended_at')
              .eq('room_id', room)
              .inFilter('state', ['ended', 'declined', 'missed'])
              .order('created_at', ascending: false)
              .limit(100);
          callHistory = calls
              .map<Map<String, dynamic>>(
                (c) => {
                  'id': 'call:${c['id']}',
                  'sender_id': c['caller_id'],
                  'created_at': c['created_at'],
                  'call_record': true,
                  'body': c['state'] == 'declined'
                      ? (c['caller_id'] == user
                            ? tr('对方已拒绝', 'Declined by recipient')
                            : tr('你已拒绝', 'You declined'))
                      : c['state'] == 'missed'
                      ? tr('未接通', 'Not answered')
                      : c['accepted_at'] == null
                      ? (c['caller_id'] == user
                            ? tr('你已取消', 'You cancelled')
                            : tr('对方已取消', 'Caller cancelled'))
                      : tr('通话已结束', 'Call ended'),
                },
              )
              .toList();
        } catch (e) {
          debugPrint('chat call history: ${e.runtimeType}');
        }
      }
      final remaining = await repo.store.pending();
      if (!mounted || denied) return;
      final old = messages.isEmpty ? null : messages.last['id'];
      setState(() {
        final combined = {
          for (final m in messages)
            if (liveIds.contains(m['id'])) m['id']: m,
          for (final m in value) m['id']: m,
        };
        messages = combined.values.toList()
          ..sort(
            (a, b) => ('${a['created_at']}${a['id']}').compareTo(
              '${b['created_at']}${b['id']}',
            ),
          );
        members = roster;
        if (currentRoom != null) title = currentRoom['title'] as String;
        pending = remaining.where((e) => e['room_id'] == room).toList();
        error = sendError == null ? null : chatError(widget.app, sendError);
        failures = sendError == null ? 0 : failures + 1;
      });
      messageChanges.value++;
      if (value.isNotEmpty && active) {
        await repo.remote.call('read', {
          'room_id': room,
          'at': value.last['created_at'],
        });
      }
      if (old != value.lastOrNull?['id']) bottom();
    } catch (e) {
      final latest = await repo.store.pending();
      if (mounted) {
        setState(() {
          pending = latest.where((m) => m['room_id'] == room).toList();
          error = chatError(widget.app, e);
          failures++;
          if (e.toString().contains('CHAT_NOT_MEMBER') ||
              repo.remote.client.auth.currentUser?.id != user) {
            denied = true;
            messages = [];
            callHistory = [];
            pending = [];
          }
        });
      }
    } finally {
      busy = false;
      timer?.cancel();
      if (mounted && active && !denied) {
        timer = Timer(
          Duration(
            seconds: failures == 0
                ? 10
                : [5, 15, 30, 60][(failures - 1).clamp(0, 3)],
          ),
          () => refresh(),
        );
      }
    }
  }

  void bottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> saveDraft() {
    if (!draftReady) return Future.value();
    final text = input.text;
    draftWrites = draftWrites
        .catchError((Object e) {
          debugPrint('Previous draft save: ${e.runtimeType}');
        })
        .then((_) => repo.store.patchRoom(room, {'draft': text}));
    return draftWrites;
  }

  void draftError(Object e) {
    if (mounted) {
      setState(
        () => error = tr(
          '草稿保存失败，请重试后再退出。',
          'Draft could not be saved. Retry before leaving.',
        ),
      );
    }
  }

  Future<void> leaveRoom() async {
    try {
      draftTimer?.cancel();
      await saveDraft();
      if (!mounted) return;
      setState(() => allowLeave = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (e) {
      draftError(e);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ChatNotifications.visibleRoom = state == AppLifecycleState.resumed
        ? widget.room['id'] as String
        : null;
    active = state == AppLifecycleState.resumed;
    if (active) {
      refresh();
    } else {
      timer?.cancel();
      unawaited(saveDraft().catchError(draftError));
    }
  }

  @override
  void dispose() {
    if (ChatNotifications.visibleRoom == widget.room['id']) {
      ChatNotifications.visibleRoom = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    debounce?.cancel();
    draftTimer?.cancel();
    unawaited(
      saveDraft().catchError(
        (Object e) => debugPrint('Draft save on dispose: ${e.runtimeType}'),
      ),
    );
    auth?.cancel();
    if (channel != null) unawaited(repo.remote.client.removeChannel(channel!));
    input.dispose();
    scroll.dispose();
    voicePlayback.dispose();
    messageChanges.dispose();
    composerFocus.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final body = input.text.trim();
    if (body.isEmpty || sending || denied) return;
    setState(() => sending = true);
    try {
      repo.remote.checkUser();
      // Only keep mentions whose "@name " text is still actually in the
      // message; the user may have deleted it after picking someone.
      final ids = [
        for (final entry in mentionIds.entries)
          if (body.contains('@${entry.value}')) entry.key,
      ];
      final all = mentionAll && body.contains('@所有人');
      await repo.store.enqueue(
        const Uuid().v4(),
        room,
        body,
        attachment: ids.isEmpty && !all
            ? null
            : {'mentions': ids, if (all) 'mention_all': true},
      );
      if (!mounted) return;
      input.clear();
      mentionIds.clear();
      mentionAll = false;
      await saveDraft();
      await refresh();
      bottom();
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> perform(String action, Map<String, dynamic> data) async {
    try {
      await repo.remote.call(action, {'room_id': room, ...data});
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    }
  }

  Future<void> attach(
    bool image, {
    bool camera = false,
    bool music = false,
    String? stickerPath,
  }) async {
    if (sending || denied) return;
    setState(() => sending = true);
    try {
      String? source, name, ext;
      if (stickerPath != null) {
        source = stickerPath;
        name = stickerPath.split(RegExp(r'[/\\]')).last;
        ext = name.split('.').last.toLowerCase();
      } else if (image) {
        final file = await ImagePicker().pickImage(
          source: camera ? ImageSource.camera : ImageSource.gallery,
        );
        if (file == null || !mounted) return;
        source = file.path;
        name = file.name;
        ext = name.split('.').last.toLowerCase();
      } else {
        final picked = await FilePicker.platform.pickFiles(
          withData: false,
          type: music ? FileType.audio : FileType.any,
        );
        if (picked == null || !mounted) return;
        source = picked.files.single.path;
        name = picked.files.single.name;
        ext = picked.files.single.extension ?? 'bin';
      }
      if (source == null) throw StateError('FILE_UNAVAILABLE');
      final local = File(source), size = await File(source).length();
      if (!image && isApk(name)) {
        if (size < 1 || size > maxApkBytes) throw StateError('APK 最大 500 MB');
        final id = const Uuid().v4();
        final staged = await ApkFiles.stage(user, id, name, source);
        repo.remote.checkUser();
        await repo.store.enqueue(
          id,
          room,
          name,
          attachment: {
            'attachment_path': '$room/$user/$id.apk',
            'attachment_name': name,
            'attachment_kind': 'file',
            'attachment_size': size,
            'mime_type': apkMime,
            'file_id': id,
            'apk_local_path': staged,
          },
        );
        await refresh();
        bottom();
        return;
      }
      if (size > (image ? 20 : 10) * 1024 * 1024) {
        setState(
          () => error = tr(
            image ? '请选择 20MB 内图片；大文件请用在线直传。' : '请选择 10MB 内文件；大文件请用在线直传。',
            'File too large. Use direct transfer for larger files.',
          ),
        );
        return;
      }
      var bytes = await local.readAsBytes();
      if (image && ext != 'gif' && stickerPath == null) {
        bytes = await compute(compressChatImage, bytes);
        ext = 'jpg';
        name = '${name.replaceFirst(RegExp(r'\.[^.]+$'), '')}.jpg';
      }
      if (bytes.length > 10 * 1024 * 1024) throw StateError('FILE_TOO_LARGE');
      repo.remote.checkUser();
      final id = const Uuid().v4();
      final path =
          '$room/$user/$id.${ext.replaceAll(RegExp('[^a-zA-Z0-9]'), '')}';
      await checkResourceUpload(
        repo.remote.client,
        name,
        bytes.length,
        mime: image ? 'image/jpeg' : '',
      );
      await repo.remote.client.storage
          .from('chat-files')
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              contentType: image
                  ? (ext == 'gif'
                        ? 'image/gif'
                        : ext == 'png'
                        ? 'image/png'
                        : ext == 'webp'
                        ? 'image/webp'
                        : 'image/jpeg')
                  : 'application/octet-stream',
            ),
          );
      repo.remote.checkUser();
      await repo.store.enqueue(
        id,
        room,
        name,
        attachment: {
          'attachment_path': path,
          'attachment_name': name,
          'attachment_kind': image ? 'image' : 'file',
          'attachment_size': bytes.length,
        },
      );
      await refresh();
      bottom();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e.toString().contains('IMAGE_')
              ? tr(
                  '此图片格式暂不支持或像素过大，请换一张图片。',
                  'Unsupported image or too many pixels. Choose another image.',
                )
              : chatError(widget.app, e),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Widget attachment(Map<String, dynamic> message) {
    final path = message['attachment_path'] as String;
    final name = message['attachment_name'] as String? ?? '';
    if (isApk(name)) {
      return ApkFileCard(
        key: ValueKey('apk:$path'),
        name: name,
        size: (message['attachment_size'] as num?)?.toInt() ?? 0,
        localPath: message['apk_local_path'] as String?,
        cached: () async {
          repo.remote.checkUser();
          final file = await ApkFiles.target(user, path, name);
          return await ApkFiles.valid(
                file,
                (message['attachment_size'] as num?)?.toInt() ?? 0,
              )
              ? file.path
              : message['apk_local_path'] as String?;
        },
        guard: repo.remote.checkUser,
        load: (progress) => ApkFiles.download(
          owner: user,
          id: path,
          name: name,
          size: (message['attachment_size'] as num?)?.toInt() ?? 0,
          guard: repo.remote.checkUser,
          progress: progress,
          url: () => repo.remote.client.storage
              .from('chat-files')
              .createSignedUrl(path, 300),
        ),
      );
    }
    final future = attachmentUrls.putIfAbsent(
      path,
      () => repo.remote.client.storage
          .from('chat-files')
          .createSignedUrl(path, 60),
    );
    return FutureBuilder<String>(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return TextButton(
            onPressed: () => setState(() => attachmentUrls.remove(path)),
            child: Text(tr('加载附件 / 重试', 'Load attachment / retry')),
          );
        }
        return InkWell(
          onTap: () async {
            try {
              if (message['attachment_kind'] == 'image') {
                final images = messages
                    .where(
                      (m) =>
                          m['attachment_kind'] == 'image' &&
                          m['attachment_path'] != null &&
                          m['recalled_at'] == null,
                    )
                    .toList();
                final index = images.indexWhere(
                  (m) => m['id'] == message['id'],
                );
                if (index >= 0) {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ChatGalleryPage(
                        app: widget.app,
                        repository: repo,
                        images: images,
                        initial: index,
                      ),
                    ),
                  );
                }
                return;
              }
              repo.remote.checkUser();
              final url = await repo.remote.client.storage
                  .from('chat-files')
                  .createSignedUrl(path, 60);
              if (!await launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              )) {
                throw StateError('open');
              }
            } catch (e) {
              if (mounted) setState(() => error = chatError(widget.app, e));
            }
          },
          child: message['attachment_kind'] == 'image'
              ? RoutedImage(
                  snapshot.data!,
                  height: 180,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.insert_drive_file_outlined),
                    Flexible(
                      child: Text(
                        '${message['attachment_name'] ?? tr('文件', 'File')}\n${message['attachment_size'] == null ? tr('打开 / 下载', 'Open / download') : '${((message['attachment_size'] as num) / 1024).toStringAsFixed(1)} KB'}',
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<void> older() async {
    if (messages.isEmpty) return;
    try {
      final rows = await repo.messages(
        room,
        before: messages.first['created_at'] as String,
      );
      if (mounted) setState(() => messages = [...rows, ...messages]);
    } catch (e) {
      if (mounted) setState(() => error = chatError(widget.app, e));
    }
  }

  Future<void> options(String action) async {
    if (action == 'qr' && group) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatQrPage(
            remote: repo.remote,
            title: title,
            roomId: room,
            owner: owner,
          ),
        ),
      );
      return;
    }
    if (action == 'delete_chat' ||
        action == 'block_user' ||
        action == 'unblock_user') {
      final isBlock = action != 'delete_chat';
      final removingBlock = action == 'unblock_user';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            isBlock
                ? (removingBlock
                      ? tr('解除拉黑？', 'Unblock this user?')
                      : tr('拉黑此用户？', 'Block this user?'))
                : tr('删除本机会话？', 'Remove local conversation?'),
          ),
          content: Text(
            isBlock
                ? (removingBlock
                      ? tr(
                          '解除后仍遵守双方的陌生人聊天设置。',
                          'Stranger-message privacy settings still apply.',
                        )
                      : tr(
                          '将阻止双方私聊和好友申请，可在此菜单解除。',
                          'Blocks messages and friend requests. Unblock from this menu.',
                        ))
                : tr(
                    '从本机会话列表移除，聊天记录和草稿保留；新消息或重新发起聊天后再次显示。',
                    'Removes this chat from the local list. History and drafts remain. New messages or reopening restore it.',
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消', 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('确认', 'Confirm')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        if (isBlock) {
          final peer = members.where((m) => m['user_id'] != user).firstOrNull;
          if (peer == null) throw StateError('missing_peer');
          await repo.remote.call('block', {
            'user_id': peer['user_id'],
            'blocked': !removingBlock,
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  removingBlock
                      ? tr('已解除拉黑', 'Unblocked')
                      : tr('已拉黑', 'Blocked'),
                ),
              ),
            );
          }
        } else {
          var marker = widget.room['updated_at'] as String?;
          try {
            final rooms = await repo.rooms();
            marker =
                rooms.where((r) => r['id'] == room).firstOrNull?['updated_at']
                    as String? ??
                marker;
          } catch (e) {
            debugPrint('Remove chat uses cached date: ${e.runtimeType}');
          }
          if (marker == null) throw StateError('missing_room_date');
          await repo.store.patchRoom(room, {
            'hiddenThrough': marker,
            'manualUnread': false,
          });
          if (mounted) await leaveRoom();
        }
      } catch (e) {
        if (mounted) setState(() => error = chatError(widget.app, e));
      }
      return;
    }
    if (action == 'pin' || action == 'mute') {
      final key = action == 'pin' ? 'pinned' : 'muted',
          value = action == 'pin' ? !pinned : !muted;
      try {
        await repo.remote.call('preferences', {'room_id': room, key: value});
        if (mounted) {
          setState(() {
            if (action == 'pin') {
              pinned = value;
            } else {
              muted = value;
            }
          });
        }
      } catch (e) {
        if (mounted) setState(() => error = chatError(widget.app, e));
      }
      return;
    }
    if (action == 'rename') {
      final next = await chatText(
        context,
        tr('修改群名', 'Rename group'),
        initial: title,
      );
      if (next == null || next.isEmpty) return;
      try {
        await repo.remote.client.rpc(
          'group_manage_v2',
          params: {
            'p_action': 'rename',
            'p_data': {'room_id': room, 'title': next},
          },
        );
        if (mounted) setState(() => title = next);
        await refresh();
      } catch (e) {
        debugPrint('Group rename: $e');
        if (mounted) setState(() => error = groupOperationError(e));
      }
      return;
    }
    if (action == 'leave') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('退出群聊？', 'Leave group?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('退出', 'Leave')),
            ),
          ],
        ),
      );
      if (yes != true) return;
      try {
        await repo.remote.call('leave', {'room_id': room});
        if (mounted) await leaveRoom();
      } catch (e) {
        if (mounted) setState(() => error = chatError(widget.app, e));
      }
      return;
    }
    if (action == 'invite') {
      final added = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
          builder: (_) => GroupInvitePage(
            app: widget.app,
            remote: repo.remote,
            roomId: room,
            createFromDirect: !group,
            memberIds: members.map((m) => m['user_id'] as String).toSet(),
          ),
        ),
      );
      if (added == true) await refresh();
      if (added is Map && added['id'] is String) {
        final rooms = await repo.rooms();
        final created = rooms.where((r) => r['id'] == added['id']).firstOrNull;
        if (mounted && created != null) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => ChatRoomPage(
                app: widget.app,
                repository: repo,
                room: created,
                live: widget.live,
              ),
            ),
          );
          ChatNotifications.visibleRoom = room;
        }
      }
      return;
    }
    if (action == 'members' && group && groupReady) {
      await roomAction('group_members');
      return;
    }
    if (action == 'members' || action == 'invite') {
      try {
        final list = ChatRepository.rows(
          await repo.remote.call(
            action == 'invite' ? 'directory' : 'members',
            action == 'invite' ? {} : {'room_id': room},
          ),
        );
        if (!mounted) return;
        final choice = await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .65,
              child: ListView(
                children: [
                  if (action == 'members')
                    ListTile(
                      leading: const Icon(Icons.person_add),
                      title: const Text('添加成员'),
                      onTap: () => Navigator.pop(ctx, {'invite_more': true}),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      action == 'invite'
                          ? tr('邀请学友（可搜索通讯录中的昵称）', 'Invite a member')
                          : tr(
                              '群成员 / 群主可移除成员',
                              'Members / owner can remove members',
                            ),
                    ),
                  ),
                  for (final p in list.where(
                    (p) =>
                        action != 'invite' ||
                        !members.any((m) => m['user_id'] == p['user_id']),
                  ))
                    ListTile(
                      title: Text(p['nickname'] as String),
                      trailing: action == 'invite'
                          ? const Icon(Icons.person_add)
                          : owner && p['user_id'] != user
                          ? const Icon(Icons.person_remove)
                          : null,
                      onTap:
                          action == 'invite' || (owner && p['user_id'] != user)
                          ? () => Navigator.pop(ctx, p)
                          : null,
                    ),
                ],
              ),
            ),
          ),
        );
        if (choice?['invite_more'] == true) {
          await options('invite');
          return;
        }
        if (choice != null) {
          if (action == 'members' && mounted) {
            final yes = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('移除此群成员？', 'Remove this member?')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(tr('取消', 'Cancel')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(tr('移除', 'Remove')),
                  ),
                ],
              ),
            );
            if (yes != true) return;
          }
          await perform(action == 'invite' ? 'invite' : 'remove', {
            'user_id': choice['user_id'],
          });
        }
      } catch (e) {
        if (mounted) setState(() => error = chatError(widget.app, e));
      }
    }
  }

  Future<void> composerAction(String action) async {
    setState(() => attachmentsOpen = false);
    try {
      switch (action) {
        case 'image':
          await attach(true);
          break;
        case 'camera':
          if (Platform.isAndroid || Platform.isIOS) {
            await attach(true, camera: true);
          } else {
            throw StateError(
              tr('此设备请使用相册选择图片', 'Choose a photo from this device'),
            );
          }
          break;
        case 'file':
          await attach(false);
          break;
        case 'music':
          await attach(false, music: true);
          break;
        case 'direct':
          if (widget.live == null) {
            throw StateError(tr('直传服务未连接', 'Direct transfer unavailable'));
          }
          await sendDirectFile(
            context,
            widget.app,
            widget.live!,
            room,
            members,
          );
          break;
        case 'call':
          if (group) {
            throw StateError(tr('目前支持一对一语音通话', 'One-to-one calls only'));
          }
          final service = VoiceCallScope.of(context);
          if (service == null) {
            throw StateError(tr('通话服务未连接', 'Call service unavailable'));
          }
          await service.start(room, title);
          break;
        case 'video':
          if (group) {
            throw StateError(tr('目前支持一对一视频通话', 'One-to-one video calls only'));
          }
          final videoService = VoiceCallScope.of(context);
          if (videoService == null) {
            throw StateError(tr('通话服务未连接', 'Call service unavailable'));
          }
          await videoService.start(room, title, video: true);
          break;
        case 'dictation':
          setState(() => voiceInput = false);
          if (Platform.isAndroid) {
            final words =
                await const MethodChannel(
                  'org.huideng.counter/speech',
                ).invokeMethod<String>(
                  'recognize',
                  widget.app.english ? 'en-US' : 'zh-CN',
                );
            if (words != null && mounted) input.text = '${input.text}$words';
          } else {
            composerFocus.requestFocus();
            throw StateError(
              tr(
                '请使用系统键盘的麦克风进行语音输入',
                'Use the microphone on your system keyboard',
              ),
            );
          }
          break;
        case 'location':
          if (!await Geolocator.isLocationServiceEnabled()) {
            throw StateError(tr('请先打开系统定位', 'Enable location services'));
          }
          var permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission == LocationPermission.denied ||
              permission == LocationPermission.deniedForever) {
            throw StateError(tr('未获得定位权限', 'Location permission not granted'));
          }
          final p = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 20),
            ),
          );
          if (!mounted) return;
          final body =
              '${tr('位置', 'Location')}: ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}\nhttps://uri.amap.com/marker?position=${p.longitude},${p.latitude}&coordinate=wgs84';
          final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(tr('发送当前位置？', 'Send current location?')),
              content: Text(body),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('取消', 'Cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('发送', 'Send')),
                ),
              ],
            ),
          );
          if (yes == true) {
            await repo.store.enqueue(const Uuid().v4(), room, body);
            await refresh();
            bottom();
          }
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Uri? locationLink(Object? body) {
    final uri = Uri.tryParse('$body'.split('\n').last);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'uri.amap.com' &&
            uri.path == '/marker' &&
            uri.queryParameters.containsKey('position')
        ? uri
        : null;
  }

  Future<void> roomAction(String value) async {
    if (group && value == 'group_admin') {
      final admin = groupAdmin ??= GroupAdmin(repo.remote.client, room);
      // GroupAdminPage can pop a follow-up action (e.g. "提醒我查看聊天" /
      // "投诉", moved there from the old level-1 menu) instead of a plain
      // void dismissal, so its own entries keep reusing this same handler.
      final next = await Navigator.push<String>(
        context,
        MaterialPageRoute<String>(
          builder: (_) => GroupAdminPage(app: widget.app, admin: admin, title: title),
        ),
      );
      await loadGroupState();
      if (mounted && next != null) await roomAction(next);
      return;
    }
    if (group &&
        (value == 'group_members' ||
            value == 'group_remove_members' ||
            value == 'group_announcements' ||
            value == 'group_files' ||
            value == 'group_pins' ||
            value == 'group_requests')) {
      final admin = groupAdmin ??= GroupAdmin(repo.remote.client, room);
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => switch (value) {
            'group_remove_members' => GroupMembersPage(
                app: widget.app,
                admin: admin,
                myRole: groupRole,
                initialSelecting: true,
              ),
            'group_announcements' => GroupAnnouncementsPage(
                app: widget.app,
                admin: admin,
                manager: groupManager,
              ),
            'group_files' => GroupFilesPage(
                app: widget.app,
                admin: admin,
                manager: groupManager,
              ),
            'group_pins' => GroupPinsPage(admin: admin, manager: groupManager),
            'group_requests' => GroupRequestsPage(admin: admin),
            _ => GroupMembersPage(app: widget.app, admin: admin, myRole: groupRole),
          },
        ),
      );
      await loadGroupState();
      return;
    }
    if (value == 'group_learning') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupLearningPage(
            app: widget.app,
            groupId: widget.room['id'],
            title: title,
          ),
        ),
      );
      return;
    }
    if (value == 'search') {
      final query = await chatText(context, tr('查找聊天记录', 'Search history'));
      if (query == null || query.trim().isEmpty || !mounted) return;
      List<Map<String, dynamic>> searchRows() => messages
          .where(
            (m) =>
                m['recalled_at'] == null &&
                chatMessageVisible(m, clearedThrough) &&
                '${m['body'] ?? ''}'.toLowerCase().contains(
                  query.toLowerCase(),
                ),
          )
          .toList();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => ValueListenableBuilder<int>(
          valueListenable: messageChanges,
          builder: (ctx, _, _) {
            final rows = searchRows();
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(ctx).height * .7,
                child: ListView(
                  children: [
                    ListTile(
                      title: Text(
                        tr('已加载记录的搜索结果', 'Results in loaded history'),
                      ),
                      subtitle: Text(
                        tr(
                          '可返回聊天加载更早消息后继续搜索',
                          'Load earlier messages in chat to search more',
                        ),
                      ),
                    ),
                    if (rows.isEmpty)
                      ListTile(title: Text(tr('没有找到', 'No matches'))),
                    for (final m in rows)
                      ListTile(
                        title: SelectableText('${m['body'] ?? ''}'),
                        subtitle: Text('${m['created_at']}'),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      return;
    }
    if (value == 'background') {
      final picked = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('聊天背景', 'Chat background')),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in [
                0,
                0xFF161616,
                0xFF16251E,
                0xFF242033,
                0xFF30231C,
                0xFFF3F0E8,
              ])
                InkWell(
                  onTap: () => Navigator.pop(ctx, color),
                  child: Container(
                    width: 60,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color == 0
                          ? Theme.of(ctx).colorScheme.surface
                          : Color(color),
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: color == 0 ? Text(tr('默认', 'Default')) : null,
                  ),
                ),
            ],
          ),
        ),
      );
      if (picked != null) {
        await repo.store.patchRoom(room, {
          'backgroundColor': picked == 0 ? null : picked,
        });
        if (mounted) {
          setState(() => backgroundColor = picked == 0 ? null : picked);
        }
      }
      return;
    }
    if (value == 'reminder') {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );
      if (time == null) return;
      var at = DateTime(
        DateTime.now().year,
        DateTime.now().month,
        DateTime.now().day,
        time.hour,
        time.minute,
      );
      if (!at.isAfter(DateTime.now())) at = at.add(const Duration(days: 1));
      try {
        await SolarReminderService.instance.remindChat(room, title, at);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('已设置本机提醒', 'Local reminder scheduled'))),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }
    if (value == 'report') {
      final reason = await chatText(
        context,
        tr('投诉原因（提交给管理员）', 'Report reason (sent to administrator)'),
      );
      if (reason == null || reason.trim().isEmpty) return;
      try {
        await repo.remote.client.from('chat_reports').insert({
          'room_id': room,
          'reporter_id': user,
          'reason': reason.trim(),
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('投诉已提交', 'Report submitted'))),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  '投诉提交失败，请稍后重试。',
                  'Report could not be submitted. Please retry later.',
                ),
              ),
            ),
          );
        }
      }
      return;
    }

    if (value == 'refresh') {
      await refresh();
      return;
    }
    if (value == 'clear_history' || value == 'restore_history') {
      try {
        if (value == 'clear_history') {
          await clearLocalChat(context, widget.app, repo, room);
        } else {
          await repo.store.patchRoom(room, {'clearedThrough': null});
        }
        final views = await repo.store.roomViews();
        if (mounted) {
          setState(
            () => clearedThrough = views[room]?['clearedThrough'] as String?,
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => error = chatError(widget.app, e));
        }
      }
      return;
    }
    if (value != 'received_files') {
      await options(value);
      return;
    }
    final files = await repo.store.read('received_files:$room');
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(tr('已接收文件（保存在本机）', 'Received files (this device)')),
            ),
            if (files.isEmpty) ListTile(title: Text(tr('暂无文件', 'No files'))),
            for (final f in files.reversed)
              ListTile(
                title: Text(f['name'] as String),
                subtitle: Text(f['at'] as String),
                onTap: () async {
                  if (isApk(f['name'] as String)) {
                    final original = File(f['path'] as String);
                    final size = await original.length();
                    if (!ctx.mounted) return;
                    await showDialog<void>(
                      context: ctx,
                      builder: (dialog) => AlertDialog(
                        content: SizedBox(
                          width: 320,
                          child: ApkFileCard(
                            name: f['name'],
                            size: size,
                            guard: repo.remote.checkUser,
                            load: (changed) async {
                              final path = await ApkFiles.stage(
                                user,
                                f['path'],
                                f['name'],
                                original.path,
                              );
                              changed(1);
                              return path;
                            },
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                    return;
                  }
                  final result = await OpenFilex.open(f['path'] as String);
                  if (ctx.mounted && result.type != ResultType.done) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          tr(
                            '无法打开，文件可能已移动或没有对应应用。',
                            'Cannot open; file may be moved or no compatible app exists.',
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  bool read(Map<String, dynamic> message) => members.any(
    (m) =>
        m['user_id'] != user &&
        (DateTime.tryParse(
                  m['read_at']?.toString() ?? '',
                )?.compareTo(DateTime.parse(message['created_at'] as String)) ??
                -1) >=
            0,
  );
  @override
  Widget build(BuildContext context) {
    final sentIds = messages.map((m) => m['id']).toSet();
    final visible = [
      ...messages.where((m) => chatMessageVisible(m, clearedThrough)),
      ...callHistory.where((m) => chatMessageVisible(m, clearedThrough)),
      ...pending
          .where((m) => !sentIds.contains(m['id']))
          .map(
            (m) => {
              ...m,
              if (m['attachment'] != null)
                ...Map<String, dynamic>.from(
                  jsonDecode(m['attachment'] as String),
                ),
              'sender_id': user,
              'pending': true,
            },
          ),
    ];
    visible.sort(
      (a, b) => ('${a['created_at']}${a['id']}').compareTo(
        '${b['created_at']}${b['id']}',
      ),
    );
    voicePlayback.updateMessages(visible);
    return PopScope(
      canPop: allowLeave,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) leaveRoom();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              if (widget.room['kind'] == 'group') ...[
                ChatAvatar(
                  app: widget.app,
                  remote: repo.remote,
                  roomId: widget.room['id'] as String,
                  groupAvatar: true,
                  avatarPath: widget.room['group_avatar_path'] as String?,
                  radius: 16,
                ),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
            ],
          ),
          actions: [
            if (group && !denied)
              IconButton(
                tooltip: tr('群文件', 'Group files'),
                icon: const Icon(Icons.folder_outlined),
                onPressed: () => roomAction('group_files'),
              ),
            if (!denied && widget.live != null)
              TransferInbox(app: widget.app, live: widget.live!, roomId: room),
            if (!denied)
              IconButton(
                tooltip: tr('聊天信息', 'Chat info'),
                icon: const Icon(Icons.more_horiz, size: 28),
                onPressed: () async {
                  final action = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatInfoPage(
                        app: widget.app,
                        repository: repo,
                        room: widget.room,
                        members: members,
                        title: title,
                        pinned: pinned,
                        muted: muted,
                        onPreference: options,
                        restoreAvailable: clearedThrough != null,
                      ),
                    ),
                  );
                  if (mounted && action != null) await roomAction(action);
                },
              ),
          ],
        ),
        body: Column(
          children: [
            ValueListenableBuilder<Map<String, double>>(
              valueListenable: ChatApkStorage.progress,
              builder: (_, values, _) => values.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        for (final value in values.values)
                          Text('Android安装包上传 ${(value * 100).floor()}%'),
                      ],
                    ),
            ),
            if (error != null)
              MaterialBanner(
                content: Text(error!),
                actions: [
                  TextButton(
                    onPressed: retryFailedApks,
                    child: Text(tr('重试', 'Retry')),
                  ),
                ],
              ),
            if (group && groupPins.isNotEmpty && groupAdmin != null)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: ListTile(
                  key: const ValueKey('group-pinned-banner'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.push_pin_outlined, size: 18),
                  title: Text(
                    '${groupPins.first['nickname']}：${(groupPins.first['body'] as String? ?? '').isEmpty ? '[附件]' : groupPins.first['body']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: groupPins.length > 1
                      ? Text('${groupPins.length} 条置顶')
                      : null,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => GroupPinsPage(
                          admin: groupAdmin!,
                          manager: groupManager,
                        ),
                      ),
                    );
                    await loadGroupState();
                  },
                ),
              ),
            Expanded(
              child: ColoredBox(
                color: backgroundColor == null
                    ? Theme.of(context).colorScheme.surface
                    : Color(backgroundColor!),
                child: ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: visible.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return TextButton(
                        onPressed: messages.length >= 100 ? older : null,
                        child: Text(tr('加载更早消息', 'Earlier messages')),
                      );
                    }
                    final m = visible[index - 1],
                        mine = m['sender_id'] == user,
                        recalled = m['recalled_at'] != null;
                    if (m['is_system'] == true) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          m['body'] as String? ?? '',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    }
                    final at = m['created_at']?.toString();
                    final previous = index > 1
                        ? visible[index - 2]['created_at']?.toString()
                        : null;
                    return Column(
                      children: [
                        if (showChatTime(at, previous))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              chatTimeLabel(
                                DateTime.parse(at!),
                                DateTime.now(),
                                english: tr('中', 'en') == 'en',
                              ),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? const Color(0xfff4f6f2)
                                        : const Color(0xff1c2820),
                                  ),
                            ),
                          ),
                        Align(
                          alignment: mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.sizeOf(context).width * .75 + 42,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              textDirection: mine
                                  ? TextDirection.rtl
                                  : TextDirection.ltr,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: ChatAvatar(
                                    app: widget.app,
                                    groupId: group
                                        ? widget.room['id'] as String
                                        : null,
                                    remote: repo.remote,
                                    userId: m['sender_id'] as String?,
                                    radius: 18,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: GestureDetector(
                                    onLongPress:
                                        recalled || m['call_record'] == true
                                        ? null
                                        : () async {
                                            final a =
                                                await showModalBottomSheet<
                                                  String
                                                >(
                                                  context: context,
                                                  builder: (ctx) => SafeArea(
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        if (widget
                                                                .room['kind'] ==
                                                            'group')
                                                          ListTile(
                                                            title: const Text(
                                                              '设为群精华（管理员）',
                                                            ),
                                                            onTap: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  'highlight',
                                                                ),
                                                          ),
                                                        if (group &&
                                                            groupManager &&
                                                            m['pending'] !=
                                                                true) ...[
                                                          ListTile(
                                                            title: const Text(
                                                              '删除（管理员，所有人同步）',
                                                            ),
                                                            onTap: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  'mod_delete',
                                                                ),
                                                          ),
                                                          ListTile(
                                                            title: const Text(
                                                              '置顶消息',
                                                            ),
                                                            onTap: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  'pin_message',
                                                                ),
                                                          ),
                                                        ],
                                                        ListTile(
                                                          title: const Text(
                                                            '保存到笔记',
                                                          ),
                                                          onTap: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                'note',
                                                              ),
                                                        ),
                                                        ListTile(
                                                          title: const Text(
                                                            '多条合并保存到笔记',
                                                          ),
                                                          onTap: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                'notes',
                                                              ),
                                                        ),
                                                        if (m['attachment_kind'] ==
                                                                'image' &&
                                                            m['attachment_path'] !=
                                                                null)
                                                          ListTile(
                                                            title: Text(
                                                              tr(
                                                                '收藏为表情',
                                                                'Save as sticker',
                                                              ),
                                                            ),
                                                            onTap: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  'sticker',
                                                                ),
                                                          ),
                                                        ListTile(
                                                          title: Text(
                                                            tr('复制', 'Copy'),
                                                          ),
                                                          onTap: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                'copy',
                                                              ),
                                                        ),
                                                        if (mine &&
                                                            m['pending'] !=
                                                                true)
                                                          ListTile(
                                                            title: Text(
                                                              tr(
                                                                '撤回',
                                                                'Recall',
                                                              ),
                                                            ),
                                                            onTap: () =>
                                                                Navigator.pop(
                                                                  ctx,
                                                                  'recall',
                                                                ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                            if (a == 'note' || a == 'notes') {
                                              if (!context.mounted) return;
                                              final saved = await Navigator.push<bool>(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => ChatSaveNotesPage(
                                                    app: widget.app,
                                                    room: room,
                                                    title: title,
                                                    messages: a == 'note'
                                                        ? [m]
                                                        : messages
                                                              .where(
                                                                (
                                                                  item,
                                                                ) => chatMessageVisible(
                                                                  item,
                                                                  clearedThrough,
                                                                ),
                                                              )
                                                              .toList(),
                                                    members: members,
                                                    initialId: m['id'],
                                                  ),
                                                ),
                                              );
                                              if (saved == true &&
                                                  context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('已保存到笔记'),
                                                  ),
                                                );
                                              }
                                            }
                                            if (a == 'highlight') {
                                              try {
                                                await AttachmentService(
                                                  repo.remote.client,
                                                ).group('content', {
                                                  'group_id': widget.room['id'],
                                                  'id': const Uuid().v4(),
                                                  'kind': 'highlight',
                                                  'title':
                                                      ((m['body'] as String? ??
                                                              '')
                                                          .isEmpty
                                                      ? '重要消息'
                                                      : (m['body'] as String)
                                                            .substring(
                                                              0,
                                                              (m['body']
                                                                      as String)
                                                                  .length
                                                                  .clamp(0, 80),
                                                            )),
                                                  'body': m['body'] ?? '',
                                                  'payload': {
                                                    'message_id': m['id'],
                                                    'sender_id': m['sender_id'],
                                                    'created_at':
                                                        m['created_at'],
                                                    'attachment_path':
                                                        m['attachment_path'],
                                                  },
                                                });
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text('已加入群精华'),
                                                    ),
                                                  );
                                                }
                                              } catch (e) {
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        '仅群主或管理员可设置群精华',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              }
                                            }
                                            if (a == 'sticker') {
                                              try {
                                                repo.remote.checkUser();
                                                final bytes = await repo
                                                    .remote
                                                    .client
                                                    .storage
                                                    .from('chat-files')
                                                    .download(
                                                      m['attachment_path']
                                                          as String,
                                                    );
                                                repo.remote.checkUser();
                                                await ChatStickerStore(
                                                  repo.store,
                                                ).add(bytes);
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        tr(
                                                          '已加入收藏表情',
                                                          'Sticker saved',
                                                        ),
                                                      ),
                                                    ),
                                                  );
                                                }
                                              } catch (e) {
                                                if (mounted) {
                                                  setState(
                                                    () => error = tr(
                                                      '收藏失败，请检查网络或图片大小',
                                                      'Could not save sticker. Check connection or image size.',
                                                    ),
                                                  );
                                                }
                                              }
                                            }
                                            if (a == 'copy') {
                                              await Clipboard.setData(
                                                ClipboardData(
                                                  text: m['body'] as String,
                                                ),
                                              );
                                            }
                                            if ((a == 'mod_delete' ||
                                                    a == 'pin_message') &&
                                                groupAdmin != null) {
                                              try {
                                                if (a == 'mod_delete') {
                                                  final r = await groupAdmin!
                                                      .deleteMessages([
                                                        m['id'] as String,
                                                      ]);
                                                  if ((r['done'] as num? ??
                                                          0) ==
                                                      0) {
                                                    throw StateError(
                                                      'CHAT_MANAGER_REQUIRED',
                                                    );
                                                  }
                                                  await refresh();
                                                } else {
                                                  await groupAdmin!.pin(
                                                    m['id'] as String,
                                                    true,
                                                  );
                                                  await loadGroupState();
                                                }
                                              } catch (e) {
                                                if (mounted) {
                                                  setState(
                                                    () => error = chatError(
                                                      widget.app,
                                                      e,
                                                    ),
                                                  );
                                                }
                                              }
                                            }
                                            if (a == 'recall') {
                                              await perform('recall', {
                                                'id': m['id'],
                                              });
                                            }
                                          },
                                    child: ChatMessageBubble(
                                      mine: mine,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 7,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (group && !mine) ...[
                                              Text(
                                                m['nickname'] as String? ??
                                                    tr('学友', 'Member'),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color:
                                                          Theme.of(
                                                                context,
                                                              ).brightness ==
                                                              Brightness.dark
                                                          ? const Color(
                                                              0xfff4f6f2,
                                                            )
                                                          : const Color(
                                                              0xff1c2820,
                                                            ),
                                                    ),
                                              ),
                                              const SizedBox(height: 3),
                                            ],
                                            if (!recalled &&
                                                (m['voice_file_id'] != null ||
                                                    m['voice_local_path'] !=
                                                        null))
                                              VoiceMessageTile(
                                                key: ValueKey(
                                                  'voice:${m['id']}',
                                                ),
                                                app: widget.app,
                                                playback: voicePlayback,
                                                message: m,
                                              )
                                            else if (!recalled &&
                                                sharedForumPostId(
                                                      m['body'] as String? ??
                                                          '',
                                                    ) !=
                                                    null)
                                              SharedForumMessage(
                                                app: widget.app,
                                                text: m['body'] as String,
                                              )
                                            else if (!recalled &&
                                                sharedResourceId(
                                                      m['body'] as String? ??
                                                          '',
                                                    ) !=
                                                    null)
                                              ResourceShareCard(
                                                app: widget.app,
                                                text: m['body'] as String,
                                              )
                                            else if (recalled ||
                                                m['attachment_kind'] != 'image')
                                              (recalled
                                                  ? Text(
                                                      mine
                                                          ? tr(
                                                              '你撤回了一条消息',
                                                              'You recalled a message',
                                                            )
                                                          : tr(
                                                              '对方撤回了一条消息',
                                                              'A message was recalled',
                                                            ),
                                                      style: const TextStyle(
                                                        fontSize: 18,
                                                        height: 1.4,
                                                      ),
                                                    )
                                                  : mentionAwareText(
                                                      m['body'] as String,
                                                      const TextStyle(
                                                        fontSize: 18,
                                                        height: 1.4,
                                                      ),
                                                      mentionsMe:
                                                          mentionsCurrentUser(
                                                            m,
                                                            user,
                                                          ),
                                                    )),
                                            if (!recalled &&
                                                locationLink(m['body']) != null)
                                              TextButton.icon(
                                                icon: const Icon(
                                                  Icons.location_on_outlined,
                                                ),
                                                label: Text(
                                                  tr('查看位置', 'Open location'),
                                                ),
                                                onPressed: () async {
                                                  try {
                                                    if (!await launchUrl(
                                                      locationLink(m['body'])!,
                                                      mode: LaunchMode
                                                          .externalApplication,
                                                    )) {
                                                      throw StateError(
                                                        'map_unavailable',
                                                      );
                                                    }
                                                  } catch (_) {
                                                    if (!mounted) return;
                                                    ScaffoldMessenger.of(
                                                      this.context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          tr(
                                                            '无法打开地图，请稍后重试',
                                                            'Could not open map',
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                },
                                              ),
                                            if (!recalled &&
                                                m['attachment_path'] != null)
                                              attachment(m),
                                            if (mine &&
                                                m['call_record'] != true)
                                              InkWell(
                                                onTap: m['pending'] == true
                                                    ? retryFailedApks
                                                    : null,
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (m['last_error'] != null)
                                                      const Icon(
                                                        Icons.error_outline,
                                                        color: Colors.red,
                                                        size: 16,
                                                      ),
                                                    Text(
                                                      m['pending'] == true
                                                          ? (m['last_error'] !=
                                                                    null
                                                                ? tr(
                                                                    '失败 · 点击重试',
                                                                    'Failed · tap to retry',
                                                                  )
                                                                : busy
                                                                ? tr(
                                                                    '发送中',
                                                                    'Sending',
                                                                  )
                                                                : tr(
                                                                    '等待发送',
                                                                    'Waiting to send',
                                                                  ))
                                                          : read(m)
                                                          ? tr('已读', 'Read')
                                                          : tr('已发送', 'Sent'),
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    ).brightness ==
                                                                    Brightness
                                                                        .dark
                                                                ? const Color(
                                                                    0xfff4f6f2,
                                                                  )
                                                                : const Color(
                                                                    0xff1c2820,
                                                                  ),
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (!denied)
              SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: tr('语音 / 键盘', 'Voice / keyboard'),
                            iconSize: 34,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 48,
                              height: 48,
                            ),
                            icon: Icon(
                              voiceInput
                                  ? Icons.keyboard_alt_outlined
                                  : Icons.volume_up_outlined,
                            ),
                            onPressed: () {
                              FocusScope.of(context).unfocus();
                              setState(() {
                                voiceInput = !voiceInput;
                                attachmentsOpen = false;
                              });
                            },
                          ),
                          Expanded(
                            child: voiceInput
                                ? HoldToRecord(
                                    app: widget.app,
                                    repository: repo,
                                    room: room,
                                    onQueued: () => refresh(),
                                  )
                                : TextField(
                                    style: const TextStyle(
                                      fontSize: 18,
                                      height: 1.4,
                                    ),
                                    controller: input,
                                    focusNode: composerFocus,
                                    onTap: () =>
                                        setState(() => attachmentsOpen = false),
                                    minLines: 1,
                                    maxLines: 5,
                                    maxLength: 8000,
                                    decoration: InputDecoration(
                                      hintText: tr('输入消息', 'Message'),
                                      counterText: '',
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 9,
                                          ),
                                      filled: true,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                          ),
                          IconButton(
                            tooltip: tr('表情', 'Emoji'),
                            icon: const Icon(
                              Icons.sentiment_satisfied_alt_outlined,
                              size: 31,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 48,
                            ),
                            onPressed: () async {
                              FocusScope.of(context).unfocus();
                              setState(() => attachmentsOpen = false);
                              final choice =
                                  await showModalBottomSheet<ChatEmojiChoice>(
                                    context: context,
                                    isScrollControlled: true,
                                    builder: (_) => ChatEmojiPanel(
                                      app: widget.app,
                                      store: repo.store,
                                    ),
                                  );
                              if (!mounted || choice == null) return;
                              if (choice.path != null) {
                                await attach(true, stickerPath: choice.path);
                                return;
                              }
                              final emoji = choice.emoji;
                              if (emoji != null && mounted) {
                                final s = input.selection;
                                final start = s.isValid
                                        ? s.start
                                        : input.text.length,
                                    end = s.isValid ? s.end : input.text.length;
                                input.value = TextEditingValue(
                                  text: input.text.replaceRange(
                                    start,
                                    end,
                                    emoji,
                                  ),
                                  selection: TextSelection.collapsed(
                                    offset: start + emoji.length,
                                  ),
                                );
                              }
                            },
                          ),

                          if (input.text.trim().isNotEmpty)
                            IconButton(
                              tooltip: tr('发送', 'Send'),
                              onPressed: sending ? null : send,
                              icon: const Icon(
                                Icons.send,
                                color: Color(0xFF69C990),
                              ),
                            )
                          else
                            IconButton(
                              tooltip: tr('更多功能', 'More actions'),
                              icon: Icon(
                                attachmentsOpen
                                    ? Icons.cancel_outlined
                                    : Icons.add_circle_outline,
                                size: 32,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 48,
                                height: 48,
                              ),
                              onPressed: () {
                                FocusScope.of(context).unfocus();
                                setState(
                                  () => attachmentsOpen = !attachmentsOpen,
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                    if (attachmentsOpen)
                      ChatAttachmentPanel(
                        english: widget.app.english,
                        enabled: !sending,
                        onSelected: composerAction,
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
