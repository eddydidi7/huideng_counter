import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/data/local/tibetan_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Chinese lunar dates are separate from Tibetan dates and include leap months',
    () async {
      final cal = await TibetanCalendar.load();
      final today = cal.at(DateTime(2026, 9, 19))!;
      expect(today['day'], 8);
      expect(today['chineseLunar']['day'], 9);
      expect(today['chineseLunar']['month'], 8);
      for (final date in [DateTime(2025, 1, 29), DateTime(2026, 2, 17)]) {
        expect(cal.at(date)!['chineseLunar']['month'], 1);
        expect(cal.at(date)!['chineseLunar']['day'], 1);
      }
      expect(cal.at(DateTime(2025, 7, 25))!['chineseLunar']['leapMonth'], true);
      expect(cal.at(DateTime(2025, 7, 25))!['chineseLunar']['month'], 6);
      expect(cal.at(DateTime(2025, 8, 23))!['chineseLunar']['month'], 7);
      expect(cal.days.values.every((r) => r['chineseLunar'] is Map), true);
    },
  );
}
