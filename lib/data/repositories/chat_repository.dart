import '../../services/chat_apk_storage.dart';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../local/chat_store.dart';
import '../remote/chat_remote.dart';
import '../../services/chat_voice_storage.dart';

class ChatRepository {
  final ChatStore store;
  final ChatRemote remote;
  Future<void>? _sending;
  ChatRepository(this.store, this.remote);
  static List<Map<String, dynamic>> rows(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e)).toList();
  Future<List<Map<String, dynamic>>> rooms() async {
    final value = rows(await remote.call('rooms'));
    await store.write('rooms', value);
    return value;
  }

  Future<List<Map<String, dynamic>>> messages(
    String room, {
    String? before,
  }) async {
    final value = rows(
      await remote.call('messages', {'room_id': room, 'before': ?before}),
    );
    if (before == null) await store.write('messages:$room', value);
    return value;
  }

  /// Reconcile older loaded pages too; absence from the latest 100 is not a
  /// deletion signal. Server checks membership and returns only live IDs.
  Future<Set<String>> existingMessages(
    String room,
    Iterable<String> ids,
  ) async {
    final list = ids.toSet().toList();
    final live = <String>{};
    for (var start = 0; start < list.length; start += 500) {
      final end = (start + 500).clamp(0, list.length);
      final result = await remote.call('message_presence', {
        'room_id': room,
        'ids': list.sublist(start, end),
      });
      live.addAll((result as List).cast<String>());
    }
    return live;
  }

  Future<void> flush() async {
    if (_sending != null) return _sending;
    final task = _flush();
    _sending = task;
    try {
      await task;
    } finally {
      _sending = null;
    }
  }

  Future<void> _flush() async {
    Object? failure;
    for (final item in await store.pending()) {
      remote.checkUser();
      if (item['last_error'] == 'APK_RETRY_REQUIRED') continue;
      final apk =
          (item['attachment'] as String?)?.contains('apk_local_path') == true;
      try {
        await store.failed(item['id'] as String, null);
        final attachment = item['attachment'] == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                jsonDecode(item['attachment'] as String),
              );
        final sent = attachment['apk_local_path'] != null
            ? await ChatApkStorage.send(remote, item, attachment)
            : attachment['voice_local_path'] != null
            ? await ChatVoiceStorage(remote).send(item, attachment)
            : Map<String, dynamic>.from(
                await remote.call('send', {
                  'id': item['id'],
                  'room_id': item['room_id'],
                  'body': item['body'],
                  if (item['attachment'] != null)
                    ...Map<String, dynamic>.from(
                      jsonDecode(item['attachment'] as String),
                    ),
                }),
              );
        // Persist acknowledgement before clearing queue, so a crash cannot lose
        // a sent message from the offline cache. UUID makes retries idempotent.
        final key = 'messages:${item['room_id']}';
        final cached = await store.read(key);
        await store.write(key, [
          ...cached.where((e) => e['id'] != sent['id']),
          sent,
        ]);
        await store.acknowledged(item['id'] as String);
      } on PostgrestException catch (e) {
        await store.failed(
          item['id'] as String,
          apk ? 'APK_RETRY_REQUIRED' : e.code ?? 'server',
        );
        failure = e;
        // A blocked/removed conversation must not starve other recipients.
        if (e.message.contains('CHAT_RATE_LIMIT')) break;
      } catch (e) {
        await store.failed(
          item['id'] as String,
          apk ? 'APK_RETRY_REQUIRED' : 'network',
        );
        rethrow;
      }
    }
    if (failure != null) throw failure;
  }
}
