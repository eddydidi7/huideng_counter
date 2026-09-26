import 'resource_upload_policy.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/remote/chat_remote.dart';

/// UUID-based immutable uploads. A failed upload never removes the local file.
class ChatVoiceStorage {
  final ChatRemote remote;
  ChatVoiceStorage(this.remote);

  static Future<Directory> directory(String user) async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/chat_voice/$user').create(recursive: true);
  }

  Future<Map<String, dynamic>> send(
    Map<String, dynamic> item,
    Map<String, dynamic> voice,
  ) async {
    remote.checkUser();
    if (remote.client.auth.currentSession?.isExpired ?? true) {
      await remote.client.auth.refreshSession();
    }
    remote.checkUser();
    final codec = voice['codec'] as String;
    final key =
        '${item['room_id']}/${remote.userId}/${voice['file_id']}.${codec == 'opus' ? 'ogg' : 'm4a'}';
    final file = File(voice['voice_local_path'] as String);
    final size = await file.length();
    await checkResourceUpload(remote.client, key, size, mime: 'audio/ogg');
    if (size == 0 || size > 10485760) throw StateError('VOICE_FILE_SIZE');
    try {
      await remote.client.storage
          .from('chat-voice')
          .upload(
            key,
            file,
            fileOptions: FileOptions(
              contentType: codec == 'opus' ? 'audio/ogg' : 'audio/mp4',
            ),
          )
          .timeout(const Duration(minutes: 2));
    } on StorageException catch (e) {
      // A prior upload can have completed before the connection was lost.
      // Never overwrite it. The RPC verifies the owned object and message UUID.
      if (e.statusCode != '409' && e.error != 'Duplicate') rethrow;
    }
    remote.checkUser();
    final result = await remote.client
        .rpc(
          'chat_voice_v1',
          params: {
            'p_data': {
              'id': item['id'],
              'room_id': item['room_id'],
              'file_id': voice['file_id'],
              'codec': codec,
              'duration_ms': voice['voice_duration_ms'],
            },
          },
        )
        .timeout(const Duration(seconds: 20));
    remote.checkUser();
    return Map<String, dynamic>.from(result);
  }

  Future<String> playable(Map<String, dynamic> message) async {
    remote.checkUser();
    final local = message['voice_local_path'] as String?;
    if (local != null && await File(local).exists()) return local;
    final id = message['voice_file_id'] as String;
    final dir = await directory(remote.userId);
    for (final extension in ['ogg', 'm4a']) {
      final file = File('${dir.path}/$id.$extension');
      if (await file.exists()) return file.path;
    }
    final metadata = await remote.client
        .from('chat_voice_files')
        .select('object_key,file_size,codec')
        .eq('id', id)
        .single();
    final bytes = await remote.client.storage
        .from('chat-voice')
        .download(metadata['object_key'] as String)
        .timeout(const Duration(seconds: 40));
    remote.checkUser();
    if (bytes.length != metadata['file_size']) {
      throw StateError('VOICE_INCOMPLETE');
    }
    final target = File(
      '${dir.path}/$id.${metadata['codec'] == 'opus' ? 'ogg' : 'm4a'}',
    );
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    return target.path;
  }
}
