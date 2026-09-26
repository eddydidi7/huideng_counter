import 'resource_upload_policy.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/remote/chat_remote.dart';
import 'apk_files.dart';

/// Progress shared with the outbox UI; failed transfers retain the staged file.
class ChatApkStorage {
  static final progress = ValueNotifier<Map<String, double>>({});
  static Future<void> upload(
    SupabaseClient client,
    String bucket,
    String key,
    File file,
    void Function() guard,
    void Function(double) changed,
  ) async {
    guard();
    final size = await file.length();
    await checkResourceUpload(client, key, size, mime: apkMime);
    if (size < 1 || size > maxApkBytes) throw StateError('APK 最大 500 MB');
    if (client.auth.currentSession?.isExpired ?? true) {
      await client.auth.refreshSession();
    }
    final endpoint = Uri.parse(
      '${client.storage.url}/object/$bucket/${key.split('/').map(Uri.encodeComponent).join('/')}',
    );
    if (endpoint.scheme != 'https') throw StateError('上传地址必须使用 HTTPS');
    guard();
    final transport = http.Client();
    try {
      final request = http.StreamedRequest('POST', endpoint)
        ..contentLength = size
        ..followRedirects = false
        ..headers.addAll(client.storage.headers)
        ..headers['authorization'] =
            'Bearer ${client.auth.currentSession!.accessToken}'
        ..headers['content-type'] = apkMime
        ..headers['cache-control'] = '3600';
      var count = 0;
      final responseFuture = transport.send(request);
      await Future.wait([
        request.sink
            .addStream(
              file.openRead().map((bytes) {
                guard();
                count += bytes.length;
                changed(count / size);
                return bytes;
              }),
            )
            .then((_) => request.sink.close()),
        responseFuture.then((_) {}),
      ]).timeout(const Duration(minutes: 30));
      final response = await responseFuture;
      final body = await response.stream.bytesToString().timeout(
        const Duration(seconds: 30),
      );
      // Immutable UUID object: retry may encounter an already completed upload.
      if (response.statusCode == 409 ||
          (response.statusCode == 400 &&
              body.contains('"error":"Duplicate"'))) {
        guard();
        return;
      }
      if (response.statusCode == 413) {
        throw StateError('超过云存储单文件限制；Supabase 免费项目最多 50 MB');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('APK 上传失败，请重试并检查存储限制');
      }
      guard();
    } finally {
      transport.close();
    }
  }

  static Future<Map<String, dynamic>> send(
    ChatRemote remote,
    Map<String, dynamic> item,
    Map<String, dynamic> attachment,
  ) async {
    remote.checkUser();
    final id = item['id'] as String;
    final path = attachment['attachment_path'] as String;
    try {
      await upload(
        remote.client,
        'chat-files',
        path,
        File(attachment['apk_local_path'] as String),
        remote.checkUser,
        (v) => progress.value = {...progress.value, id: v},
      );
      remote.checkUser();
      return Map<String, dynamic>.from(
        await remote.call('send', {
          'id': id,
          'room_id': item['room_id'],
          'body': item['body'],
          'attachment_path': path,
          'attachment_name': attachment['attachment_name'],
          'attachment_kind': 'file',
        }),
      );
    } finally {
      progress.value = Map.of(progress.value)..remove(id);
    }
  }
}
