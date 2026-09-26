import 'dart:convert';

class ChineseCalendarEvents {
  static const defaultJson = r'''{
  "2025-01-01": {
    "zh": "节日：元旦",
    "en": "Festival: New Year’s Day"
  },
  "2025-01-05": {
    "zh": "节气：小寒",
    "en": "Solar term: Minor Cold"
  },
  "2025-01-07": {
    "zh": "节日：腊八节",
    "en": "Festival: Laba Festival"
  },
  "2025-01-20": {
    "zh": "节气：大寒",
    "en": "Solar term: Major Cold"
  },
  "2025-01-28": {
    "zh": "节日：除夕",
    "en": "Festival: Lunar New Year’s Eve"
  },
  "2025-01-29": {
    "zh": "节日：春节",
    "en": "Festival: Spring Festival"
  },
  "2025-02-03": {
    "zh": "节气：立春",
    "en": "Solar term: Start of Spring"
  },
  "2025-02-12": {
    "zh": "节日：元宵节",
    "en": "Festival: Lantern Festival"
  },
  "2025-02-18": {
    "zh": "节气：雨水",
    "en": "Solar term: Rain Water"
  },
  "2025-03-01": {
    "zh": "节日：龙抬头",
    "en": "Festival: Dragon Head Raising Festival"
  },
  "2025-03-05": {
    "zh": "节气：惊蛰",
    "en": "Solar term: Awakening of Insects"
  },
  "2025-03-20": {
    "zh": "节气：春分",
    "en": "Solar term: Spring Equinox"
  },
  "2025-04-04": {
    "zh": "节气：清明 · 清明节",
    "en": "Solar term: Pure Brightness"
  },
  "2025-04-20": {
    "zh": "节气：谷雨",
    "en": "Solar term: Grain Rain"
  },
  "2025-05-01": {
    "zh": "节日：劳动节",
    "en": "Festival: Labour Day"
  },
  "2025-05-05": {
    "zh": "节气：立夏",
    "en": "Solar term: Start of Summer"
  },
  "2025-05-21": {
    "zh": "节气：小满",
    "en": "Solar term: Grain Buds"
  },
  "2025-05-31": {
    "zh": "节日：端午节",
    "en": "Festival: Dragon Boat Festival"
  },
  "2025-06-01": {
    "zh": "节日：儿童节",
    "en": "Festival: Children’s Day"
  },
  "2025-06-05": {
    "zh": "节气：芒种",
    "en": "Solar term: Grain in Ear"
  },
  "2025-06-21": {
    "zh": "节气：夏至",
    "en": "Solar term: Summer Solstice"
  },
  "2025-07-07": {
    "zh": "节气：小暑",
    "en": "Solar term: Minor Heat"
  },
  "2025-07-22": {
    "zh": "节气：大暑",
    "en": "Solar term: Major Heat"
  },
  "2025-08-07": {
    "zh": "节气：立秋",
    "en": "Solar term: Start of Autumn"
  },
  "2025-08-23": {
    "zh": "节气：处暑",
    "en": "Solar term: End of Heat"
  },
  "2025-08-29": {
    "zh": "节日：七夕",
    "en": "Festival: Qixi Festival"
  },
  "2025-09-06": {
    "zh": "节日：中元节",
    "en": "Festival: Zhongyuan Festival"
  },
  "2025-09-07": {
    "zh": "节气：白露",
    "en": "Solar term: White Dew"
  },
  "2025-09-10": {
    "zh": "节日：教师节",
    "en": "Festival: Teachers’ Day"
  },
  "2025-09-23": {
    "zh": "节气：秋分",
    "en": "Solar term: Autumn Equinox"
  },
  "2025-10-01": {
    "zh": "节日：国庆节",
    "en": "Festival: National Day"
  },
  "2025-10-06": {
    "zh": "节日：中秋节",
    "en": "Festival: Mid-Autumn Festival"
  },
  "2025-10-08": {
    "zh": "节气：寒露",
    "en": "Solar term: Cold Dew"
  },
  "2025-10-23": {
    "zh": "节气：霜降",
    "en": "Solar term: Frost Descent"
  },
  "2025-10-29": {
    "zh": "节日：重阳节",
    "en": "Festival: Double Ninth Festival"
  },
  "2025-11-07": {
    "zh": "节气：立冬",
    "en": "Solar term: Start of Winter"
  },
  "2025-11-22": {
    "zh": "节气：小雪",
    "en": "Solar term: Minor Snow"
  },
  "2025-12-07": {
    "zh": "节气：大雪",
    "en": "Solar term: Major Snow"
  },
  "2025-12-21": {
    "zh": "节气：冬至",
    "en": "Solar term: Winter Solstice"
  },
  "2026-01-01": {
    "zh": "节日：元旦",
    "en": "Festival: New Year’s Day"
  },
  "2026-01-05": {
    "zh": "节气：小寒",
    "en": "Solar term: Minor Cold"
  },
  "2026-01-20": {
    "zh": "节气：大寒",
    "en": "Solar term: Major Cold"
  },
  "2026-01-26": {
    "zh": "节日：腊八节",
    "en": "Festival: Laba Festival"
  },
  "2026-02-04": {
    "zh": "节气：立春",
    "en": "Solar term: Start of Spring"
  },
  "2026-02-16": {
    "zh": "节日：除夕",
    "en": "Festival: Lunar New Year’s Eve"
  },
  "2026-02-17": {
    "zh": "节日：春节",
    "en": "Festival: Spring Festival"
  },
  "2026-02-18": {
    "zh": "节气：雨水",
    "en": "Solar term: Rain Water"
  },
  "2026-03-03": {
    "zh": "节日：元宵节",
    "en": "Festival: Lantern Festival"
  },
  "2026-03-05": {
    "zh": "节气：惊蛰",
    "en": "Solar term: Awakening of Insects"
  },
  "2026-03-20": {
    "zh": "节气：春分 · 龙抬头",
    "en": "Solar term: Spring Equinox · Dragon Head Raising Festival"
  },
  "2026-04-05": {
    "zh": "节气：清明 · 清明节",
    "en": "Solar term: Pure Brightness"
  },
  "2026-04-20": {
    "zh": "节气：谷雨",
    "en": "Solar term: Grain Rain"
  },
  "2026-05-01": {
    "zh": "节日：劳动节",
    "en": "Festival: Labour Day"
  },
  "2026-05-05": {
    "zh": "节气：立夏",
    "en": "Solar term: Start of Summer"
  },
  "2026-05-21": {
    "zh": "节气：小满",
    "en": "Solar term: Grain Buds"
  },
  "2026-06-01": {
    "zh": "节日：儿童节",
    "en": "Festival: Children’s Day"
  },
  "2026-06-05": {
    "zh": "节气：芒种",
    "en": "Solar term: Grain in Ear"
  },
  "2026-06-19": {
    "zh": "节日：端午节",
    "en": "Festival: Dragon Boat Festival"
  },
  "2026-06-21": {
    "zh": "节气：夏至",
    "en": "Solar term: Summer Solstice"
  },
  "2026-07-07": {
    "zh": "节气：小暑",
    "en": "Solar term: Minor Heat"
  },
  "2026-07-23": {
    "zh": "节气：大暑",
    "en": "Solar term: Major Heat"
  },
  "2026-08-07": {
    "zh": "节气：立秋",
    "en": "Solar term: Start of Autumn"
  },
  "2026-08-19": {
    "zh": "节日：七夕",
    "en": "Festival: Qixi Festival"
  },
  "2026-08-23": {
    "zh": "节气：处暑",
    "en": "Solar term: End of Heat"
  },
  "2026-08-27": {
    "zh": "节日：中元节",
    "en": "Festival: Zhongyuan Festival"
  },
  "2026-09-07": {
    "zh": "节气：白露",
    "en": "Solar term: White Dew"
  },
  "2026-09-10": {
    "zh": "节日：教师节",
    "en": "Festival: Teachers’ Day"
  },
  "2026-09-23": {
    "zh": "节气：秋分",
    "en": "Solar term: Autumn Equinox"
  },
  "2026-09-25": {
    "zh": "节日：中秋节",
    "en": "Festival: Mid-Autumn Festival"
  },
  "2026-10-01": {
    "zh": "节日：国庆节",
    "en": "Festival: National Day"
  },
  "2026-10-08": {
    "zh": "节气：寒露",
    "en": "Solar term: Cold Dew"
  },
  "2026-10-18": {
    "zh": "节日：重阳节",
    "en": "Festival: Double Ninth Festival"
  },
  "2026-10-23": {
    "zh": "节气：霜降",
    "en": "Solar term: Frost Descent"
  },
  "2026-11-07": {
    "zh": "节气：立冬",
    "en": "Solar term: Start of Winter"
  },
  "2026-11-22": {
    "zh": "节气：小雪",
    "en": "Solar term: Minor Snow"
  },
  "2026-12-07": {
    "zh": "节气：大雪",
    "en": "Solar term: Major Snow"
  },
  "2026-12-22": {
    "zh": "节气：冬至",
    "en": "Solar term: Winter Solstice"
  }
}''';
  static Map<String, dynamic> defaults() =>
      jsonDecode(defaultJson) as Map<String, dynamic>;
  static bool valid(dynamic value) {
    if (value is! Map || value.length > 2000) return false;
    for (final e in value.entries) {
      if (e.key is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(e.key)) {
        return false;
      }
      final date = DateTime.tryParse(e.key);
      if (date == null || date.toIso8601String().substring(0, 10) != e.key) {
        return false;
      }
      if (e.value is! Map) return false;
      for (final lang in ['zh', 'en']) {
        if (e.value[lang] is! String ||
            (e.value[lang] as String).length > 2000) {
          return false;
        }
      }
    }
    return true;
  }

  ChineseCalendarEvents(dynamic value)
    : data = valid(value)
          ? Map<String, dynamic>.from(value as Map)
          : defaults();
  final Map<String, dynamic> data;
  String at(String date, bool english) =>
      data[date]?[english ? 'en' : 'zh'] as String? ?? '';
}
