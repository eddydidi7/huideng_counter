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
import '../services/chat_image.dart';

const defaultChatAvatar = 'assets/images/default_chat_avatar.png';
final _avatarVersion = ValueNotifier(0);
final _avatarCache = <String, ({DateTime at, Future<String?> value})>{};

final _signedAvatars = <String, ({DateTime until, String url})>{};

class ChatAvatar extends StatelessWidget {
  final ChatRemote? remote;
  final SupabaseClient? publicClient;
  final String? userId, roomId;
  final double radius;
  final double? cornerRadius;
  const ChatAvatar({
    super.key,
    this.remote,
    this.publicClient,
    this.userId,
    this.roomId,
    this.radius = 20,
    this.cornerRadius,
  });
  Future<String?> load() async {
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
      var id = userId;
      if (id == null && roomId != null) {
        final members = await api.call('members', {'room_id': roomId}) as List;
        id =
            members
                    .where((m) => m['user_id'] != api.userId)
                    .firstOrNull?['user_id']
                as String?;
      }
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
      final cacheKey = '${identityHashCode(api.client)}:${api.userId}:$path';
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
    } catch (e) {
      debugPrint('Chat avatar fallback: ${e.runtimeType}');
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
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _avatarVersion,
    builder: (context, version, _) {
      final key =
          '${identityHashCode(remote?.client ?? publicClient)}:${remote?.userId}:$userId:$roomId:$version';
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
