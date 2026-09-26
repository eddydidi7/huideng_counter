import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/local/chat_store.dart';
import '../data/remote/chat_remote.dart';
import 'chat_notification_settings.dart';
import 'solar_reminder_service.dart';

/// A live-connection transport, not a substitute for OS/vendor push.
/// Future push adapters must pass only IDs into receive(), never trust payload text.
class ChatNotifications {
  static String? visibleRoom;
  final SupabaseClient client;
  final String user;
  RealtimeChannel? channel;
  bool closed = false;
  Future<void> tail = Future.value();
  ChatNotifications(this.client, this.user);
  void start() {
    if (!Platform.isAndroid) return;
    // Also read a cold-start notification tap when solar reminders are disabled.
    unawaited(
      SolarReminderService.instance
          .notifications()
          .then<void>((_) {})
          .catchError((Object e) {
            debugPrint('Notification initialization: ${e.runtimeType}');
          }),
    );
    channel = client
        .channel('chat-notifications:$user')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_messages',
          callback: (event) {
            final row = event.newRecord.isEmpty
                ? event.oldRecord
                : event.newRecord;
            final id = row['id'] as String?, room = row['room_id'] as String?;
            if (id == null) return;
            tail = tail
                .then((_) async {
                  if (closed) return;
                  if (row['recalled_at'] != null ||
                      event.eventType == PostgresChangeEvent.delete) {
                    await (await SolarReminderService.instance.notifications())
                        .cancel(1, tag: 'chat:$user:$id');
                  } else if (event.eventType == PostgresChangeEvent.insert &&
                      room != null) {
                    await receive(room, id);
                  }
                })
                .catchError((Object e) {
                  debugPrint('Chat notification: ${e.runtimeType}');
                });
          },
        )
        .subscribe();
  }

  Future<void> receive(String roomId, String messageId) async {
    final remote = ChatRemote(client, user);
    final rooms = await remote.call('rooms') as List;
    final room = rooms.where((r) => r['id'] == roomId).firstOrNull;
    if (room == null) return;
    // Fetch current server state: a recalled message from an old push is ignored.
    final messages = await remote.call('messages', {'room_id': roomId}) as List;
    final message = messages
        .where((m) => m['id'] == messageId && m['recalled_at'] == null)
        .firstOrNull;
    if (message == null || message['sender_id'] == user || closed) return;
    // A muted group still notifies for members marked "特别关注" on this device.
    if (room['muted'] == true) {
      final view = (await (await ChatStore.open(user)).roomViews())[roomId];
      final special = [for (final id in view?['specialFollow'] as List? ?? []) '$id'];
      if (!special.contains(message['sender_id'])) return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = 'chat.notifications.seen.$user';
    final seen = prefs.getStringList(key) ?? <String>[];
    if (seen.contains(messageId)) return;
    await prefs.setStringList(key, [
      ...seen.skip(seen.length > 1999 ? seen.length - 1999 : 0),
      messageId,
    ]);
    final settings = await ChatNotificationSettings.load(user);
    if (!settings.enabled ||
        visibleRoom == roomId ||
        (room['kind'] == 'group' ? !settings.group : !settings.direct)) {
      return;
    }
    final quiet = settings.quietAt(DateTime.now());
    final sound = settings.sound && !quiet && settings.ringtone != 'silent';
    final vibration = settings.vibrate && !quiet;
    final variant = sha256
        .convert(utf8.encode('$sound|$vibration|$quiet|${settings.ringtone}'))
        .toString()
        .substring(0, 12);
    final plugin = await SolarReminderService.instance.notifications();
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (await android?.areNotificationsEnabled() != true || closed) return;
    remote.checkUser();
    final body = message['body'] as String? ?? '';
    final preview = body.isEmpty
        ? '收到一个附件'
        : String.fromCharCodes(body.runes.take(160));
    await plugin.show(
      1,
      room['title'] as String? ?? '慧灯计数器',
      settings.preview
          ? (room['kind'] == 'group'
                ? '${message['nickname'] ?? ''}：$preview'
                : preview)
          : '收到一条新消息',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_messages_$variant',
          '聊天消息',
          channelDescription: '聊天消息；声音与震动可在系统通知设置中调整',
          tag: 'chat:$user:$messageId',
          groupKey: 'chat:$user:$roomId',
          importance: quiet ? Importance.low : Importance.high,
          priority: quiet ? Priority.low : Priority.high,
          playSound: sound,
          enableVibration: vibration,
          sound: sound && settings.ringtone != 'default'
              ? UriAndroidNotificationSound(settings.ringtone)
              : null,
          visibility: settings.preview
              ? NotificationVisibility.private
              : NotificationVisibility.secret,
        ),
      ),
      payload: 'chat:$user:$roomId',
    );
  }

  Future<void> dispose() async {
    closed = true;
    if (channel != null) await client.removeChannel(channel!);
  }
}
