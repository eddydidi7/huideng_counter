/// Tibetan lunar dates, never Gregorian or Chinese lunar dates.
/// Religious observances vary by lineage; grooming text is user-supplied folklore.
class ObservanceDetail {
  final int month, day;
  final String zh, en, source;
  const ObservanceDetail(this.month, this.day, this.zh, this.en, this.source);
}

class CalendarObservances {
  static const sources = <String, (String, String)>{
    'fpmt': (
      'FPMT · 修持日期说明',
      'https://fpmt.org/media/resources/dharma-dates/dates-explained/',
    ),
    'sakya': (
      'Sakya Centre · 纪念日历',
      'https://www.glorioussakya.org/schedule/lunar-calendar/',
    ),
    'guru': (
      'Lotsawa House · 初十日释义',
      'https://www.lotsawahouse.org/tibetan-masters/gonpo-tseten-rinpoche/bouquet-of-udumbara-flowers',
    ),
    'tsongkhapa': (
      'Lotsawa House · 宗喀巴大师祈祷文注释',
      'https://www.lotsawahouse.org/tibetan-masters/jamyang-khyentse-chokyi-lodro/tsongkhapa-prayer',
    ),
  };

  // Supplement existing names without overwriting user-requested observances.
  static const additionalMonthly = <ObservanceDetail>[
    ObservanceDetail(0, 8, '度母日', 'Tara practice day', 'fpmt'),
    ObservanceDetail(0, 8, '八关斋戒修持日', 'Eight Mahayana precepts day', 'fpmt'),
    ObservanceDetail(
      0,
      15,
      '药师佛修持日 · 八关斋戒修持日',
      'Medicine Buddha and eight precepts day',
      'fpmt',
    ),
    ObservanceDetail(0, 29, '护法日', 'Dharma protector day', 'fpmt'),
    ObservanceDetail(0, 30, '八关斋戒修持日', 'Eight Mahayana precepts day', 'fpmt'),
  ];

  // Lineage anniversaries are explicitly attributed, not universal holidays.
  static const additionalAnnual = <ObservanceDetail>[
    ObservanceDetail(
      1,
      15,
      '玛尔巴译师圆寂纪念日（萨迦中心历）',
      'Marpa anniversary (Sakya Centre calendar)',
      'sakya',
    ),
    ObservanceDetail(
      1,
      21,
      '蒋扬钦哲旺波圆寂纪念日（萨迦中心历）',
      'Jamyang Khyentse Wangpo anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      1,
      26,
      '萨迦班智达诞辰纪念日（萨迦中心历）',
      'Sakya Pandita birth anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      2,
      12,
      '扎巴坚赞圆寂纪念日（萨迦中心历）',
      'Drakpa Gyaltsen anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      3,
      15,
      '佛陀初传时轮金刚纪念日（萨迦中心历）',
      'First Kalachakra teaching (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      4,
      23,
      '毗鲁巴成就纪念日（萨迦中心历）',
      'Virupa accomplishment anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      5,
      6,
      '蒋扬钦哲却吉罗卓圆寂纪念日（萨迦中心历）',
      'Jamyang Khyentse Chokyi Lodro anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      6,
      10,
      '莲花生大士诞辰纪念日（六月初十传统）',
      'Guru Rinpoche birth anniversary (sixth-month tradition)',
      'guru',
    ),
    ObservanceDetail(
      9,
      14,
      '萨钦贡嘎宁波圆寂纪念日（萨迦中心历）',
      'Sachen Kunga Nyingpo anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      10,
      25,
      '宗喀巴大师圆寂纪念日 · 燃灯节',
      'Je Tsongkhapa anniversary · Ganden Ngamcho',
      'tsongkhapa',
    ),
    ObservanceDetail(
      11,
      14,
      '萨迦班智达纪念日（萨迦中心历）',
      'Sakya Pandita anniversary (Sakya Centre)',
      'sakya',
    ),
    ObservanceDetail(
      11,
      22,
      '八思巴圆寂纪念日（萨迦中心历）',
      'Chogyal Phagpa anniversary (Sakya Centre)',
      'sakya',
    ),
  ];
  static const miraclesPeriod = ObservanceDetail(
    1,
    1,
    '神变十五日（正月初一至十五）',
    'Fifteen Days of Miracles (month 1, days 1–15)',
    'fpmt',
  );

  static List<ObservanceDetail> additionsFor(Map<String, dynamic> row) => [
    ...additionalMonthly.where((e) => e.day == row['day']),
    if (row['leapMonth'] != true) ...[
      if (row['month'] == 1 &&
          (row['day'] as int) >= 1 &&
          (row['day'] as int) <= 15)
        miraclesPeriod,
      if (row['repeatIndex'] != 1)
        ...additionalAnnual.where(
          (e) => e.month == row['month'] && e.day == row['day'],
        ),
    ],
  ];

  static bool hasObservance(Map<String, dynamic> row) =>
      monthly.containsKey(row['day']) || additionsFor(row).isNotEmpty;

  static const monthly = <int, (String, String)>{
    8: ('药师佛日', 'Medicine Buddha day'),
    10: ('莲师荟供日', 'Guru Rinpoche tsok day'),
    15: ('阿弥陀佛日', 'Amitabha Buddha day'),
    18: ('观世音菩萨日', 'Avalokiteshvara day'),
    21: ('地藏菩萨日', 'Kshitigarbha day'),
    25: ('空行母荟供日', 'Dakini tsok day'),
    30: ('释迦牟尼佛日', 'Shakyamuni Buddha day'),
  };
  static const haircut = <(String, String)>[
    ('生命短', 'Shorter life'),
    ('病多，麻烦多', 'Illness and troubles'),
    ('变成富裕人家', 'Becoming a prosperous household'),
    ('怀业增广，气色好', 'Increasing magnetizing activity and a good complexion'),
    ('增长财物', 'Increasing possessions'),
    ('气色转衰', 'Declining complexion'),
    ('易招闲言，麻烦多', 'Gossip and troubles'),
    ('长寿', 'Longevity'),
    ('易遇年轻女子', 'Meeting young women'),
    ('增长快乐', 'Increasing happiness'),
    ('增长出世间的智慧与世间的聪明', 'Increasing spiritual wisdom and worldly intelligence'),
    ('招病，生命危险', 'Illness and danger to life'),
    ('精进于佛法，最好', 'Diligence in Dharma; most favorable'),
    ('东西增多', 'Increasing belongings'),
    ('增上福报', 'Increasing merit'),
    ('得病', 'Illness'),
    ('容易失明，皮肤变绿', 'Loss of sight and green skin'),
    ('丢失财物', 'Loss of possessions'),
    ('佛法增长', 'Growth in Dharma'),
    ('容易挨饿，不好', 'Hunger; unfavorable'),
    ('易招传染病', 'Infectious illness'),
    ('病情加重', 'Worsening illness'),
    ('家族富裕', 'Family prosperity'),
    ('遇传染病', 'Infectious illness'),
    ('得沙眼，出迎风泪', 'Trachoma and watery eyes in the wind'),
    ('得安乐', 'Peace and comfort'),
    ('吉祥', 'Auspiciousness'),
    ('易发生打架', 'Fighting'),
    ('掉魂，声音变哑', 'Loss of soul and a hoarse voice'),
    ('预见被争讼及死人', 'Disputes, litigation and encounters with the dead'),
  ];
  static const goodWashingDays = {
    3,
    4,
    5,
    6,
    8,
    10,
    11,
    13,
    14,
    15,
    16,
    18,
    19,
    22,
    23,
    26,
    27,
  };
  static (String, String) haircutFor(int day) {
    RangeError.checkValueInInterval(day, 1, 30, 'day');
    return haircut[day - 1];
  }

  static bool washingGood(int day) {
    RangeError.checkValueInInterval(day, 1, 30, 'day');
    return goodWashingDays.contains(day);
  }

  static (String, String)? specialHaircut(
    int month,
    int day, {
    bool leapMonth = false,
  }) {
    if (leapMonth) return null;
    if ((month == 10 || month == 11) && day == 8) {
      return (
        '本月特别说明：剪发可以忏净罪孽',
        'Special monthly note: cutting hair is said to purify wrongdoing',
      );
    }
    if (month == 12 && day == 25) {
      return (
        '本月特别说明：剪发可以增长智慧（与每月二十五日通则并列保留）',
        'Special monthly note: cutting hair is said to increase wisdom; retained alongside the general day-25 entry',
      );
    }
    return null;
  }

  static bool annualCaution(int month, int day, {bool leapMonth = false}) =>
      !leapMonth && month == 11 && (day == 6 || day == 7);
  static const annualHaircutNote = (
    '藏历每年的十月初八，十一月初八剪发可以忏净罪孽；十二月二十五日剪发可以增长智慧。',
    'In the Tibetan calendar, haircuts on the eighth day of months ten and eleven purify wrongdoing; haircuts on the twenty-fifth day of month twelve increase wisdom.',
  );
  static const traditionNote = (
    '理发婴儿除外。',
    'Haircut guidance excludes infants.',
  );
  static const sourceNote = (
    '理发、洗头资料：用户提供，转述归于第司桑吉嘉措《白琉璃论》',
    'Haircut and hair-washing material: supplied by the user, attributed to Desi Sangye Gyatso’s White Beryl.',
  );
  static const hairHandling = (
    '所附传统说明（原文）：灌顶后理发理下的头发最好放于高山上、水中或烧掉，应持心咒“嗡玛呢达呢呢舍轰 阿呢巴夏达热舍 达呸梭哈”。',
    'Supplied traditional note: after empowerment, cut hair is said to be placed on a high mountain, in water or burned while reciting the supplied mantra (original transcription): 嗡玛呢达呢呢舍轰 阿呢巴夏达热舍 达呸梭哈。',
  );
}
