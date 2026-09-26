import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/calendar_observances.dart';
import 'package:huideng_counter/data/local/tibetan_calendar.dart';

void main() {
  test('additions coexist and respect leap/repeated day rules', () {
    Map<String, dynamic> row(
      int m,
      int d, {
      int repeat = 0,
      bool leap = false,
    }) => {'month': m, 'day': d, 'repeatIndex': repeat, 'leapMonth': leap};
    final fullMoon = row(1, 15);
    expect(TibetanCalendar.festival(fullMoon), 'miracles');
    expect(
      CalendarObservances.additionsFor(fullMoon).map((e) => e.zh),
      containsAll(['药师佛修持日 · 八关斋戒修持日', '神变十五日（正月初一至十五）', '玛尔巴译师圆寂纪念日（萨迦中心历）']),
    );
    expect(CalendarObservances.additionsFor(row(6, 10)).single.source, 'guru');
    expect(
      CalendarObservances.additionsFor(row(10, 25)).single.source,
      'tsongkhapa',
    );
    expect(CalendarObservances.additionsFor(row(6, 10, repeat: 1)), isEmpty);
    expect(
      CalendarObservances.additionsFor(row(6, 10, repeat: 2)),
      hasLength(1),
    );
    expect(CalendarObservances.additionsFor(row(6, 10, leap: true)), isEmpty);
    expect(
      CalendarObservances.additionsFor(row(1, 8, leap: true)),
      hasLength(2),
    );
    expect(CalendarObservances.hasObservance(row(8, 29)), isTrue);
    expect(CalendarObservances.hasObservance(row(1, 2)), isTrue);
    expect(CalendarObservances.hasObservance(row(1, 16)), isFalse);
    expect(CalendarObservances.hasObservance(row(2, 2)), isFalse);
    for (final entry in [
      ...CalendarObservances.additionalMonthly,
      ...CalendarObservances.additionalAnnual,
    ]) {
      expect(CalendarObservances.sources.containsKey(entry.source), isTrue);
      expect(entry.zh, isNotEmpty);
      expect(entry.en, isNotEmpty);
    }
  });

  test('all 30 grooming days and exact washing partition', () {
    expect(CalendarObservances.haircut.length, 30);
    const bad = {1, 2, 7, 9, 12, 17, 20, 21, 24, 25, 28, 29, 30};
    for (var d = 1; d <= 30; d++) {
      expect(CalendarObservances.haircutFor(d).$1, isNotEmpty);
      expect(CalendarObservances.haircutFor(d).$2, isNotEmpty);
      expect(CalendarObservances.washingGood(d), !bad.contains(d));
    }
    expect(() => CalendarObservances.haircutFor(0), throwsRangeError);
    expect(() => CalendarObservances.washingGood(31), throwsRangeError);
  });
  test(
    'annual exceptions preserve general day rule and do not guess leap months',
    () {
      expect(CalendarObservances.specialHaircut(10, 8)?.$1, contains('忏净'));
      expect(CalendarObservances.specialHaircut(11, 8)?.$1, contains('忏净'));
      expect(CalendarObservances.specialHaircut(12, 25)?.$1, contains('智慧'));
      expect(CalendarObservances.haircutFor(25).$1, contains('沙眼'));
      expect(
        CalendarObservances.specialHaircut(12, 25, leapMonth: true),
        isNull,
      );
      expect(CalendarObservances.specialHaircut(9, 8), isNull);
      expect(CalendarObservances.annualCaution(11, 6), isTrue);
      expect(CalendarObservances.annualCaution(11, 7), isTrue);
      expect(CalendarObservances.annualCaution(11, 8), isFalse);
    },
  );
  test('monthly names and annual festivals are separate', () {
    expect(CalendarObservances.monthly[8]?.$1, '药师佛日');
    expect(CalendarObservances.monthly[10]?.$1, '莲师荟供日');
    expect(CalendarObservances.monthly[15]?.$1, '阿弥陀佛日');
    expect(CalendarObservances.monthly[21]?.$1, '地藏菩萨日');
    expect(CalendarObservances.monthly[30]?.$1, '释迦牟尼佛日');
    Map<String, dynamic> row(int m, int d, int repeat, bool leap) => {
      'month': m,
      'day': d,
      'repeatIndex': repeat,
      'leapMonth': leap,
    };
    expect(TibetanCalendar.festival(row(4, 7, 0, false)), 'birth');
    expect(TibetanCalendar.festival(row(4, 15, 0, false)), 'saga');
    expect(TibetanCalendar.festival(row(6, 4, 0, false)), 'wheel');
    expect(TibetanCalendar.festival(row(9, 22, 0, false)), 'descent');
    expect(TibetanCalendar.festival(row(4, 7, 1, false)), isNull);
    expect(TibetanCalendar.festival(row(4, 7, 2, false)), 'birth');
    expect(TibetanCalendar.festival(row(4, 7, 0, true)), isNull);
  });
}
