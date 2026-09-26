import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/data/local/tibetan_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bundled days are consecutive, with verified holidays and explicit repeated/skipped days',
    () async {
      final cal = await TibetanCalendar.load();
      expect(cal.days, hasLength(730));
      for (
        var date = DateTime.utc(2025);
        date.isBefore(DateTime.utc(2027));
        date = date.add(const Duration(days: 1))
      ) {
        final r = cal.at(date)!;
        expect(r['day'], inInclusiveRange(1, 30));
        expect(r['month'], inInclusiveRange(1, 12));
        if (r['repeatIndex'] == 2) {
          final prev = cal.at(date.subtract(const Duration(days: 1)))!;
          expect(prev['repeatIndex'], 1);
          expect(prev['day'], r['day']);
        }
        expect(
          (r['skippedBefore'] as List).every((d) => d >= 1 && d <= 30),
          isTrue,
        );
      }
      expect(
        cal.days.values.where((r) => r['repeatIndex'] != 0),
        hasLength(30),
      );
      expect(cal.at(DateTime(2026, 9, 15))!['day'], 4);
      expect(cal.at(DateTime(2026, 9, 15))!['month'], 8);
      expect(
        TibetanCalendar.festival(cal.at(DateTime(2026, 11, 1))!),
        'descent',
      );
      expect(TibetanCalendar.festival(cal.at(DateTime(2026, 5, 31))!), 'saga');
      expect(cal.eclipses['2025-09-08'], 'lunarTotal');
      expect(cal.eclipses['2026-08-13'], 'solarTotal');
      expect(cal.at(DateTime(2027)), isNull);
    },
  );
}
