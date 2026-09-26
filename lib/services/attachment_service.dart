import 'apk_files.dart';
import 'chat_apk_storage.dart';
import 'cloud_storage_provider.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Immutable file objects, shared by reference. ACL is checked on each new URL.
class AttachmentService {
  AttachmentService(this.client) : owner = client.auth.currentUser!.id;
  final SupabaseClient client;
  late final CloudStorageProvider storage = SupabaseStorageProvider(client);
  final String owner;
  void guard() {
    if (client.auth.currentUser?.id != owner) throw StateError('账号已变化');
  }

  Future<dynamic> group(String action, Map<String, dynamic> data) async {
    guard();
    final r = await client.rpc(
      'group_learning_v1',
      params: {'p_action': action, 'p_data': data},
    );
    guard();
    return r;
  }

  Future<void> uploadGroup(
    String groupId,
    String path,
    String name, {
    bool album = false,
    String? folderId,
  }) async {
    guard();
    final file = File(path);
    final size = await file.length();
    if (size < 1 || size > (isApk(name) ? maxApkBytes : 104857600)) {
      throw StateError('文件过大：APK 最大500MB，其他文件最大100MB');
    }
    final checksum = (await sha256.bind(file.openRead()).first).toString();
    final id = isApk(name)
        ? const Uuid().v5(
            '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
            '$groupId/$owner/$name/$checksum',
          )
        : const Uuid().v4();
    guard();
    final reservation = await group('file_reserve', {
      'group_id': groupId,
      'id': id,
      'file_size': size,
    });
    if (isApk(name)) {
      if (reservation is Map && reservation['committed'] == true) return;
      try {
        await ChatApkStorage.upload(
          client,
          'group-files',
          '$groupId/$owner/$id.apk',
          file,
          guard,
          (value) => ChatApkStorage.progress.value = {
            ...ChatApkStorage.progress.value,
            id: value,
          },
        );
      } finally {
        ChatApkStorage.progress.value = Map.of(ChatApkStorage.progress.value)
          ..remove(id);
      }
    } else {
      await storage.upload('group-files', '$groupId/$owner/$id', file);
    }
    guard();
    await group('file_add', {
      'group_id': groupId,
      'id': id,
      'file_name': name,
      'file_size': size,
      'checksum': checksum,
      'album': album,
      'folder_id': folderId,
    });
  }

  Future<String> download(Map<String, dynamic> file) async {
    guard();
    final url = await client.storage
        .from(file['bucket'] as String)
        .createSignedUrl(file['object_key'] as String, 60);
    guard();
    final dir = await getApplicationSupportDirectory();
    final suffix = (file['file_name'] as String)
        .split('.')
        .last
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final target = File(
      '${dir.path}/group_${file['file_id']}_${DateTime.now().microsecondsSinceEpoch}.$suffix',
    );
    final transport = http.Client();
    try {
      final response = await transport.send(
        http.Request('GET', Uri.parse(url)),
      );
      if (response.statusCode != 200) throw StateError('下载失败');
      final sink = target.openWrite();
      int size = 0;
      try {
        await for (final bytes in response.stream) {
          guard();
          size += bytes.length;
          if (size > (file['file_size'] as num).toInt()) {
            throw StateError('文件大小不匹配');
          }
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if (size != (file['file_size'] as num).toInt() ||
          (await sha256.bind(target.openRead()).first).toString() !=
              file['checksum']) {
        throw StateError('文件校验失败');
      }
      guard();
      return target.path;
    } finally {
      transport.close();
    }
  }
}
