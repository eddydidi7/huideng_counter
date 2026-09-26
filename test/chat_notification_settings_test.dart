import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/services/chat_notification_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('quiet hours cross midnight with exclusive end', () {
    final s = ChatNotificationSettings()..quiet = true;
    expect(s.quietAt(DateTime(2026, 9, 21, 22)), true);
    expect(s.quietAt(DateTime(2026, 9, 22, 6, 59)), true);
    expect(s.quietAt(DateTime(2026, 9, 22, 7)), false);
    expect(s.quietAt(DateTime(2026, 9, 22, 12)), false);
    s.start = 9 * 60;
    s.end = 17 * 60;
    expect(s.quietAt(DateTime(2026, 9, 22, 12)), true);
    expect(s.quietAt(DateTime(2026, 9, 22, 19)), false);
  });
  test(
    'sound/vibration and local account preferences remain independent',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = ChatNotificationSettings()
        ..sound = false
        ..vibrate = true
        ..preview = false
        ..group = false
        ..ringtone = 'content://media/1';
      await s.save('a');
      final loaded = await ChatNotificationSettings.load('a');
      expect(loaded.sound, false);
      expect(loaded.vibrate, true);
      expect(loaded.preview, false);
      expect(loaded.group, false);
      expect(loaded.ringtone, 'content://media/1');
      expect((await ChatNotificationSettings.load('b')).sound, true);
    },
  );
}
