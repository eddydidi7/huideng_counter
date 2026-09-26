import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/chinese_calendar_events.dart';

void main() {
  test('solar terms and festivals follow actual dates and may overlap', () {
    final c = ChineseCalendarEvents(null);
    expect(ChineseCalendarEvents.valid(c.data), true);
    expect(c.at('2026-02-04', false), contains('立春'));
    expect(c.at('2026-02-17', false), contains('春节'));
    expect(c.at('2026-06-19', false), contains('端午'));
    expect(c.at('2026-09-25', false), contains('中秋'));
    expect(c.at('2026-02-16', false), contains('除夕'));
    expect(c.at('2026-09-19', false), isEmpty);
    expect(c.at('2025-10-06', false), contains('中秋'));
    expect(c.data.values.where((e) => e['zh'].startsWith('节气：')).length, 48);
  });
  test('backend replaces, adds and hides descriptions with validation', () {
    final data = {
      '2026-09-19': {'zh': '当日介绍', 'en': 'Today'},
    };
    expect(ChineseCalendarEvents(data).at('2026-09-19', false), '当日介绍');
    expect(ChineseCalendarEvents({}).at('2026-02-04', false), isEmpty);
    expect(
      ChineseCalendarEvents.valid({
        '2026-02-30': {'zh': 'bad', 'en': ''},
      }),
      false,
    );
    expect(
      ChineseCalendarEvents.valid({
        '2026-02-04': {'zh': 4, 'en': ''},
      }),
      false,
    );
  });
}
