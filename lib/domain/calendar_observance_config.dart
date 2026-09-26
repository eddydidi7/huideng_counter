import 'calendar_observances.dart';

/// Versioned data only: never downloaded executable code.
class CalendarObservanceConfig {
  CalendarObservanceConfig(dynamic value)
    : data = valid(value)
          ? Map<String, dynamic>.from(value as Map)
          : defaults();
  final Map<String, dynamic> data;
  static Map<String, dynamic> defaults() {
    var n = 0;
    Map<String, dynamic> entry(
      int month,
      int day,
      String zh,
      String en, {
      int? end,
      String source = '',
      String url = '',
    }) => {
      'id': 'builtin_${++n}',
      'month': month,
      'day': day,
      'end_day': end ?? day,
      'zh': zh,
      'en': en,
      'source': source,
      'url': url,
      'enabled': true,
      'include_leap': month == 0,
      'repeat': month == 0 || end != null ? 'both' : 'second',
    };
    Map<String, dynamic> fromDetail(ObservanceDetail d) {
      final source = CalendarObservances.sources[d.source]!;
      return entry(
        d.month,
        d.day,
        d.zh,
        d.en,
        source: source.$1,
        url: source.$2,
      );
    }

    final annual = <(int, int, String, String)>[
      (1, 1, '藏历新年', 'Losar'),
      (1, 15, '神变节', 'Chotrul Duchen'),
      (4, 7, '释迦牟尼佛诞辰日（四月初七传统）', 'Buddha birth (month 4/day 7 tradition)'),
      (4, 15, '萨嘎达瓦节 · 佛陀成道、涅槃日', 'Saga Dawa · Enlightenment and parinirvana'),
      (6, 4, '佛陀初转法轮日', 'First turning of the Dharma wheel'),
      (9, 22, '天降日', 'Lhabab Duchen'),
    ];
    return {
      'schema': 1,
      'highlight_months': [1, 4, 6, 9],
      'title_zh': '殊胜日与佛教节日对照',
      'title_en': 'Practice days & festivals',
      'note_zh':
          '以上均为藏历。佛诞与莲师诞辰有不同传统；各纪念日标明所采用的资料。月度纪念通常在重日两天显示，年度纪念默认在第二重日、非闰月显示；缺日不自动移节。原有地藏等月度名称保留用户提供的汉文藏历标注。',
      'note_en':
          'Tibetan dates. Birth traditions vary. Monthly entries normally appear on both repeated dates; annual entries on the second occurrence and outside leap months. Skipped dates are not shifted. Some original monthly names follow user-supplied Chinese-language almanacs.',
      'entries': [
        for (final e in CalendarObservances.monthly.entries)
          entry(
            0,
            e.key,
            e.key == 8 ? '药师佛加持日 · 作何善恶成千倍' : e.value.$1,
            e.value.$2,
            source: '用户提供的汉文藏历标注',
          ),
        for (final d in CalendarObservances.additionalMonthly) fromDetail(d),
        entry(
          1,
          1,
          CalendarObservances.miraclesPeriod.zh,
          CalendarObservances.miraclesPeriod.en,
          end: 15,
          source: CalendarObservances.sources['fpmt']!.$1,
          url: CalendarObservances.sources['fpmt']!.$2,
        ),
        for (final d in annual)
          entry(
            d.$1,
            d.$2,
            d.$3,
            d.$4,
            source: CalendarObservances
                .sources[d.$1 == 4 && d.$2 == 7 ? 'sakya' : 'fpmt']!
                .$1,
            url: CalendarObservances
                .sources[d.$1 == 4 && d.$2 == 7 ? 'sakya' : 'fpmt']!
                .$2,
          ),
        for (final d in CalendarObservances.additionalAnnual) fromDetail(d),
        entry(
          6,
          15,
          '佛陀入胎日',
          'Buddha conception day',
          source: '用户提供的藏历纪念日资料（六月十五）',
        ),
      ],
    };
  }

  static bool valid(dynamic v) {
    if (v is! Map ||
        v['schema'] != 1 ||
        v['entries'] is! List ||
        (v['entries'] as List).length > 500) {
      return false;
    }
    for (final k in ['title_zh', 'title_en', 'note_zh', 'note_en']) {
      if (v[k] is! String || (v[k] as String).length > 10000) return false;
    }
    if (v.containsKey('highlight_months')) {
      final months = v['highlight_months'];
      if (months is! List ||
          months.length > 12 ||
          months.any((m) => m is! int || m < 1 || m > 12) ||
          months.toSet().length != months.length) {
        return false;
      }
    }
    final ids = <String>{};
    for (final e in v['entries']) {
      if (e is! Map) return false;
      for (final k in ['id', 'zh', 'en', 'source', 'url']) {
        if (e[k] is! String || (e[k] as String).length > 2000) return false;
      }
      if ((e['id'] as String).isEmpty ||
          !ids.add(e['id']) ||
          (e['zh'] as String).trim().isEmpty) {
        return false;
      }
      if (e['month'] is! int ||
          e['month'] < 0 ||
          e['month'] > 12 ||
          e['day'] is! int ||
          e['day'] < 1 ||
          e['day'] > 30 ||
          e['end_day'] is! int ||
          e['end_day'] < e['day'] ||
          e['end_day'] > 30 ||
          e['enabled'] is! bool ||
          e['include_leap'] is! bool ||
          !['both', 'first', 'second'].contains(e['repeat'])) {
        return false;
      }
      if (e['url'] != '') {
        final uri = Uri.tryParse(e['url']);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          return false;
        }
      }
    }
    return true;
  }

  List<int> get highlightedMonths =>
      List<int>.from(data['highlight_months'] ?? [1, 4, 6, 9]);
  bool isHighlightedMonth(Map<String, dynamic> row) =>
      highlightedMonths.contains(row['month']) && row['leapMonth'] != true;

  List<Map<String, dynamic>> get entries => (data['entries'] as List)
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  List<Map<String, dynamic>> at(Map<String, dynamic> row) => entries
      .where(
        (e) =>
            e['enabled'] == true &&
            (e['month'] == 0 || e['month'] == row['month']) &&
            row['day'] >= e['day'] &&
            row['day'] <= e['end_day'] &&
            (row['leapMonth'] != true || e['include_leap'] == true) &&
            !(row['repeatIndex'] == 1 && e['repeat'] == 'second') &&
            !(row['repeatIndex'] == 2 && e['repeat'] == 'first'),
      )
      .toList();
}
