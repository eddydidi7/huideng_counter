import 'dart:convert';
import 'package:flutter/services.dart';

class TibetanCalendar {
  final Map<String, Map<String, dynamic>> days;
  final Map<String, dynamic> eclipses;
  TibetanCalendar(this.days, this.eclipses);
  static const monthNames = [
    '神变月',
    '苦行月',
    '具香月',
    '萨嘎月',
    '作净月',
    '法轮月（明净月）',
    '具醉月',
    '具贤月',
    '天降月',
    '持众月',
    '庄严月',
    '满意月',
  ];
  static const monthNamesEn = [
    'Miracles',
    'Austerities',
    'Fragrance',
    'Saga Dawa',
    'Purification',
    'Turning the Wheel',
    'Intoxication',
    'Excellence',
    'Descent from Heaven',
    'Gathering',
    'Adornment',
    'Satisfaction',
  ];
  static const dayNames = [
    '初一',
    '初二',
    '初三',
    '初四',
    '初五',
    '初六',
    '初七',
    '初八',
    '初九',
    '初十',
    '十一',
    '十二',
    '十三',
    '十四',
    '十五',
    '十六',
    '十七',
    '十八',
    '十九',
    '二十',
    '廿一',
    '廿二',
    '廿三',
    '廿四',
    '廿五',
    '廿六',
    '廿七',
    '廿八',
    '廿九',
    '三十',
  ];
  static const practiceDays = {8, 10, 15, 18, 21, 25, 29, 30};
  static String key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static Future<TibetanCalendar> load() async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'assets/calendar/tibetan_2025_2026.json',
              ),
            )
            as Map<String, dynamic>;
    final lunarData =
        jsonDecode(
              await rootBundle.loadString(
                'assets/calendar/chinese_lunar_2025_2026.json',
              ),
            )
            as Map<String, dynamic>;
    return TibetanCalendar({
      for (final r in data['days'] as List)
        r['date'] as String: {
          ...Map<String, dynamic>.from(r),
          'chineseLunar': lunarData['days'][r['date']],
        },
    }, Map<String, dynamic>.from(data['eclipses']));
  }

  Map<String, dynamic>? at(DateTime day) => days[key(day)];
  static String? festival(Map<String, dynamic> r) {
    if (r['leapMonth'] == true || r['repeatIndex'] == 1) return null;
    return switch ((r['month'], r['day'])) {
      (1, 1) => 'losar',
      (1, 15) => 'miracles',
      (4, 7) => 'birth',
      (4, 15) => 'saga',
      (6, 4) => 'wheel',
      (9, 22) => 'descent',
      _ => null,
    };
  }
}
