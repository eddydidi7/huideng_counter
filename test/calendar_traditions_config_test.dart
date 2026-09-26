import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/calendar_traditions.dart';
import 'package:huideng_counter/domain/calendar_observances.dart';

void main() {
  test('offline defaults preserve all thirty daily entries', () {
    final c = CalendarTraditions(null);
    for (var d = 1; d <= 30; d++) {
      expect(c.day(d, 'haircut', false), CalendarObservances.haircutFor(d).$1);
      expect(
        c.day(d, 'washing', false),
        CalendarObservances.washingGood(d) ? '好' : '不好',
      );
    }
  });
  test(
    'remote table and attribution are used, invalid configuration falls back',
    () {
      final v = CalendarTraditions.defaults();
      v['texts']['source']['zh'] = '管理员来源';
      v['days'][6]['haircut']['zh'] = '修改后的初七';
      final c = CalendarTraditions(v);
      expect(c.text('source', false), '管理员来源');
      expect(c.day(7, 'haircut', false), '修改后的初七');
      v['days'].removeLast();
      expect(CalendarTraditions.valid(v), false);
      expect(
        CalendarTraditions(v).day(7, 'haircut', false),
        CalendarObservances.haircutFor(7).$1,
      );
      expect(CalendarTraditions.defaults()['days'].length, 30);
    },
  );
}
