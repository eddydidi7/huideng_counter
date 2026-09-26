import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ChatNotificationSettings {
  bool enabled = true, sound = true, vibrate = true, preview = true;
  bool direct = true, group = true, quiet = false;
  int start = 22 * 60, end = 7 * 60;
  String ringtone = 'default';
  bool quietAt(DateTime time) {
    if (!quiet) return false;
    final minute = time.hour * 60 + time.minute;
    return start == end ||
        (start < end
            ? minute >= start && minute < end
            : minute >= start || minute < end);
  }

  static Future<ChatNotificationSettings> load(String user) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = ChatNotificationSettings();
    final raw = prefs.getString('chat.notifications.$user');
    if (raw == null) return settings;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      settings.enabled = map['enabled'] != false;
      settings.sound = map['sound'] != false;
      settings.vibrate = map['vibrate'] != false;
      settings.preview = map['preview'] != false;
      settings.direct = map['direct'] != false;
      settings.group = map['group'] != false;
      settings.quiet = map['quiet'] == true;
      settings.start = (map['start'] as int? ?? 1320).clamp(0, 1439);
      settings.end = (map['end'] as int? ?? 420).clamp(0, 1439);
      settings.ringtone = map['ringtone'] as String? ?? 'default';
    } catch (_) {
      /* Corrupt preferences never interrupt chat delivery. */
    }
    return settings;
  }

  Future<void> save(String user) async {
    await (await SharedPreferences.getInstance()).setString(
      'chat.notifications.$user',
      jsonEncode({
        'enabled': enabled,
        'sound': sound,
        'vibrate': vibrate,
        'preview': preview,
        'direct': direct,
        'group': group,
        'quiet': quiet,
        'start': start,
        'end': end,
        'ringtone': ringtone,
      }),
    );
  }
}
