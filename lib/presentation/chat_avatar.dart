import '../services/resource_upload_policy.dart';
import 'routed_image.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/remote/chat_remote.dart';
import '../data/remote/group_admin.dart';
import '../services/chat_image.dart';
import 'profile_navigation.dart';

const defaultChatAvatar = 'assets/images/default_chat_avatar.png';
final _avatarVersion = ValueNotifier(0);
final _avatarCache = <String, ({DateTime at, Future<String?> value})>{};

/// Forces every mounted [ChatAvatar] on this device to refetch, e.g. right
/// after this user saved a new personal or group avatar.
void bumpChatAvatarVersion() {
  _avatarCache.clear();
  _avatarVersion.value++;
}

/// Bumped whenever the signed-in user's own nickname changes, from any
/// entry point (profile page, chat settings sheet). Screens that keep their
/// own cached copy of "my nickname" (e.g. ChatPage's app bar) listen to
/// this to refetch immediately instead of waiting for their next periodic
/// refresh. This does not attempt to live-refresh every place a nickname
/// is shown app-wide (forum posts, group member lists, etc.) — those
/// already refetch on their own normal reload cycle, same as before.
final ownNicknameVersion = ValueNotifier(0);
void bumpOwnNicknameVersion() => ownNicknameVersion.value++;

final _signedAvatars = <String, ({DateTime until, String url})>{};

/// All user-avatar surfaces use this widget. Taps open the shared profile;
/// callers may keep long-press/selection actions on the enclosing row.
/// Group avatars are not people and retain their existing group action.
class ChatAvatar extends StatefulWidget {
  final AppController app;
  final ChatRemote? remote;
  final SupabaseClient? publicClient;
  final String? userId, roomId;
  final String? groupId, publicProfileId, imageUrl;
  final double radius;
  final double? cornerRadius;

  /// When true and [roomId] is set with no [userId], shows the GROUP's own
  /// avatar (chat_group_settings.avatar_path) instead of a member's.
  final bool groupAvatar;

  /// Skips any lookup and signs this path directly. Pass this whenever the
  /// caller already has the group's avatar_path (e.g. from the 'rooms' list,
  /// which includes it as group_avatar_path) — chat_group_settings has no
  /// direct SELECT grant, so without this every group-avatar render would
  /// otherwise have to go through group_admin_v1('overview') just to read it.
  final String? avatarPath;
  const ChatAvatar({
    super.key,
    required this.app,
    this.remote,
    this.publicClient,
    this.userId,
    this.roomId,
    this.radius = 20,
    this.cornerRadius,
    this.groupAvatar = false,
    this.avatarPath,
    this.groupId,
    this.publicProfileId,
    this.imageUrl,
  });

  Future<String?> resolveUserId() async {
    if (userId?.isNotEmpty == true) return userId;
    final api = remote;
    if (groupAvatar || api == null || roomId == null) return null;
    api.checkUser();
    final members = await api.call('members', {'room_id': roomId}) as List;
    api.checkUser();
    final peers = members
        .map((m) => m['user_id'])
        .whereType<String>()
        .where((id) => id.isNotEmpty && id != api.userId)
        .toSet();
    return peers.length == 1 ? peers.single : null;
  }

  Future<String?> _sign(ChatRemote api, String path, String cacheKey) async {
    final old = _signedAvatars[cacheKey];
    if (old != null && old.until.isAfter(DateTime.now())) return old.url;
    final url = await api.client.storage
        .from('chat-avatars')
        .createSignedUrl(path, 300)
        .timeout(const Duration(seconds: 15));
    api.checkUser();
    if (_signedAvatars.length > 500) _signedAvatars.clear();
    _signedAvatars[cacheKey] = (
      until: DateTime.now().add(const Duration(seconds: 270)),
      url: url,
    );
    return url;
  }

  Future<String?> load() async {
    if (publicProfileId != null) {
      if (imageUrl?.isNotEmpty == true) return imageUrl;
      if (avatarPath == null || publicClient == null) return null;
      try {
        return await publicClient!.storage
            .from('chat-avatars')
            .createSignedUrl(avatarPath!, 300);
      } catch (_) {
        return null;
      }
    }
    final api = remote;
    if (api == null) {
      final client = publicClient;
      if (client == null || userId == null) return null;
      try {
        final path = await client.rpc<dynamic>(
          'public_forum_avatar',
          params: {'p_user_id': userId},
        );
        if (path is! String || path.isEmpty) return null;
        return await client.storage
            .from('chat-avatars')
            .createSignedUrl(path, 300);
      } catch (e) {
        debugPrint('Public avatar fallback: ${e.runtimeType}');
        return null;
      }
    }
    try {
      api.checkUser();
      if (userId == null && roomId != null && groupAvatar) {
        String? path = avatarPath;
        if (path == null) {
          // chat_group_settings has no direct SELECT grant; go through the
          // same RPC group_admin_page.dart uses instead of querying it.
          final overview = await GroupAdmin(api.client, roomId!).overview();
          api.checkUser();
          path = (overview['settings'] as Map?)?['avatar_path'] as String?;
        }
        if (path == null) return null;
        return await _sign(
          api,
          path,
          '${identityHashCode(api.client)}:group:$roomId:$path',
        );
      }
      final id = await resolveUserId();
      if (id == null) return null;
      final profile = await api.client
          .from('chat_profiles')
          .select('avatar_path')
          .eq('user_id', id)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));
      api.checkUser();
      final path = profile?['avatar_path'] as String?;
      if (path == null) return null;
      return await _sign(
        api,
        path,
        '${identityHashCode(api.client)}:${api.userId}:$path',
      );
    } catch (e) {
      debugPrint('Chat avatar fallback: ${e.runtimeType}: $e');
      return null;
    }
  }

  Widget fallback() => Image.asset(
    defaultChatAvatar,
    fit: BoxFit.cover,
    alignment: const Alignment(0, 0),
    cacheWidth: 256,
  );
  @override
  State<ChatAvatar> createState() => _ChatAvatarState();

  Widget image(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _avatarVersion,
    builder: (context, version, _) {
      final key =
          '${identityHashCode(remote?.client ?? publicClient)}:${remote?.userId}:$userId:$roomId:$groupAvatar:$avatarPath:$publicProfileId:$imageUrl:$version';
      var entry = _avatarCache[key];
      if (entry == null || DateTime.now().difference(entry.at).inSeconds > 60) {
        if (_avatarCache.length > 500) _avatarCache.clear();
        entry = (at: DateTime.now(), value: load());
        _avatarCache[key] = entry;
      }
      return ClipRRect(
        // A shared gentle corner ratio keeps avatars consistent in the chat
        // list, messages, member lists, search and public profiles.
        borderRadius: BorderRadius.circular(cornerRadius ?? radius * .44),
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: FutureBuilder<String?>(
            future: entry.value,
            builder: (_, snapshot) {
              final url = snapshot.data;
              return url == null
                  ? fallback()
                  : RoutedImage(
                      url,
                      fit: BoxFit.cover,
                      cacheWidth: (radius * 4).round().clamp(48, 256),
                      errorBuilder: (_, _, _) => fallback(),
                    );
            },
          ),
        ),
      );
    },
  );
}

class _ChatAvatarState extends State<ChatAvatar> {
  bool opening = false;
  Future<void> open() async {
    if (opening) return;
    opening = true;
    try {
      final id = await widget.resolveUserId();
      if (!mounted) return;
      await openUserProfile(
        context,
        widget.app,
        userId: id,
        publicId: widget.publicProfileId,
        groupId: widget.groupId,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('暂时无法打开个人主页，请稍后重试')));
      }
    } finally {
      opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image(context);
    if (widget.groupAvatar) return image;
    // Only claim taps. Parent long-press and selection gestures keep working.
    return Semantics(
      button: true,
      label:
          widget.userId == widget.app.cloud?.client?.auth.currentUser?.id &&
              widget.userId != null
          ? '我的个人主页'
          : '查看个人主页',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: image,
      ),
    );
  }
}

class ChatAvatarPage extends StatefulWidget {
  final AppController app;
  final ChatRemote remote;
  const ChatAvatarPage({super.key, required this.app, required this.remote});
  @override
  State<ChatAvatarPage> createState() => _ChatAvatarPageState();
}

class _ChatAvatarPageState extends State<ChatAvatarPage> {
  bool busy = false;
  String? error;
  String tr(String zh, String en) => widget.app.text(zh, en);
  Future<void> update(bool reset) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final api = widget.remote;
    try {
      api.checkUser();
      String? path;
      if (!reset) {
        final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (image == null) return;
        if (await image.length() > 10 * 1024 * 1024) throw StateError('size');
        final data = await compute(
          compressChatAvatar,
          await File(image.path).readAsBytes(),
        );
        if (data.length > 2 * 1024 * 1024) throw StateError('size');
        api.checkUser();
        path = '${api.userId}/${const Uuid().v4()}.jpg';
        await checkResourceUpload(
          api.client,
          path,
          data.length,
          mime: 'image/jpeg',
        );
        await api.client.storage
            .from('chat-avatars')
            .uploadBinary(
              path,
              data,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );
      }
      api.checkUser();
      await api.client
          .rpc('chat_avatar_v1', params: {'p_path': path})
          .timeout(const Duration(seconds: 20));
      api.checkUser();
      _avatarCache.clear();
      _avatarVersion.value++;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('头像已保存', 'Avatar saved'))));
      }
    } catch (e) {
      debugPrint('Chat avatar update failed: ${e.runtimeType}');
      if (mounted) {
        setState(
          () => error =
              resourceLimitMessage(e) ??
              tr(
                '头像保存失败，请检查网络或稍后重试。原图需小于10MB，处理后小于2MB。',
                'Could not save. Check connection or try later; source must be under 10MB and processed image under 2MB.',
              ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('我的头像', 'My avatar'))),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ChatAvatar(
            app: widget.app,
            remote: widget.remote,
            userId: widget.remote.userId,
            radius: 70,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          tr(
            '默认使用四臂观音。更换后随账号保存，聊天中的其他用户也能看到。',
            'Defaults to the supplied image. A custom avatar is saved to your account and visible to other chat users.',
          ),
        ),
        if (error != null) Text(error!),
        if (busy) const LinearProgressIndicator(),
        FilledButton(
          onPressed: busy ? null : () => update(false),
          child: Text(tr('从相册更换头像', 'Choose an image')),
        ),
        TextButton(
          onPressed: busy ? null : () => update(true),
          child: Text(tr('恢复默认头像', 'Restore default avatar')),
        ),
      ],
    ),
  );
}
