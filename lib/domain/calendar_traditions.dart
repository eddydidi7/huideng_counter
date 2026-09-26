import 'dart:convert';
import 'chinese_calendar_events.dart';

// Same schema/defaults in the mobile app and admin editor.
class CalendarTraditions {
  static const defaultJson = r'''{
  "texts": {
    "heading": {
      "zh": "理发与洗头",
      "en": "Haircut & hair washing"
    },
    "tableTitle": {
      "zh": "查看每月完整对照表",
      "en": "View the complete monthly table"
    },
    "haircutLabel": {
      "zh": "理发",
      "en": "Haircut"
    },
    "washingLabel": {
      "zh": "洗头",
      "en": "Hair washing"
    },
    "caution": {
      "zh": "每年十一月初六、初七“大凶日，大事勿用”",
      "en": "Traditional caution: days 6 and 7 of month 11 are unfavorable for major undertakings."
    },
    "tableAnnual": {
      "zh": "年度特别说明：十月初八、十一月初八剪发可以忏净罪孽；十二月二十五日剪发可以增长智慧。每年十一月初六、初七“大凶日，大事勿用”。",
      "en": "Annual notes: month 10/day 8 and month 11/day 8 purify wrongdoing; month 12/day 25 increases wisdom. Month 11/days 6 and 7 are unfavorable for major undertakings."
    },
    "annual": {
      "zh": "藏历每年的十月初八，十一月初八剪发可以忏净罪孽；十二月二十五日剪发可以增长智慧。",
      "en": "In the Tibetan calendar, haircuts on the eighth day of months ten and eleven purify wrongdoing; haircuts on the twenty-fifth day of month twelve increase wisdom."
    },
    "infant": {
      "zh": "理发婴儿除外。",
      "en": "Haircut guidance excludes infants."
    },
    "source": {
      "zh": "（根据第司桑吉嘉措所著的历法书《白琉璃论》）",
      "en": "(According to White Beryl by Desi Sangye Gyatso)"
    },
    "handling": {
      "zh": "灌顶后理发理下的头发最好放于高山上、水中或烧掉，应持心咒“嗡玛呢达呢呢舍轰 阿呢巴夏达热舍 达呸梭哈”。",
      "en": "Supplied traditional note: after empowerment, cut hair is said to be placed on a high mountain, in water or burned while reciting the supplied mantra (original transcription): 嗡玛呢达呢呢舍轰 阿呢巴夏达热舍 达呸梭哈。"
    },
    "specialPurify": {
      "zh": "本月特别说明：剪发可以忏净罪孽",
      "en": "Special monthly note: cutting hair purifies wrongdoing"
    },
    "specialWisdom": {
      "zh": "本月特别说明：剪发可以增长智慧",
      "en": "Special monthly note: cutting hair increases wisdom; alongside the general day-25 entry"
    }
  },
  "days": [
    {
      "haircut": {
        "zh": "生命短",
        "en": "Shorter life"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "病多，麻烦多",
        "en": "Illness and troubles"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "变成富裕人家",
        "en": "Becoming a prosperous household"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "怀业增广，气色好",
        "en": "Increasing magnetizing activity and a good complexion"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "增长财物",
        "en": "Increasing possessions"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "气色转衰",
        "en": "Declining complexion"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "易招闲言，麻烦多",
        "en": "Gossip and troubles"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "长寿",
        "en": "Longevity"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "易遇年轻女子",
        "en": "Meeting young women"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "增长快乐",
        "en": "Increasing happiness"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "增长出世间的智慧与世间的聪明",
        "en": "Increasing spiritual wisdom and worldly intelligence"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "招病，生命危险",
        "en": "Illness and danger to life"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "精进于佛法，最好",
        "en": "Diligence in Dharma; most favorable"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "东西增多",
        "en": "Increasing belongings"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "增上福报",
        "en": "Increasing merit"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "得病",
        "en": "Illness"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "容易失明，皮肤变绿",
        "en": "Loss of sight and green skin"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "丢失财物",
        "en": "Loss of possessions"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "佛法增长",
        "en": "Growth in Dharma"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "容易挨饿，不好",
        "en": "Hunger; unfavorable"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "易招传染病",
        "en": "Infectious illness"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "病情加重",
        "en": "Worsening illness"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "家族富裕",
        "en": "Family prosperity"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "遇传染病",
        "en": "Infectious illness"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "得沙眼，出迎风泪",
        "en": "Trachoma and watery eyes in the wind"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "得安乐",
        "en": "Peace and comfort"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "吉祥",
        "en": "Auspiciousness"
      },
      "washing": {
        "zh": "好",
        "en": "Favorable"
      }
    },
    {
      "haircut": {
        "zh": "易发生打架",
        "en": "Fighting"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "掉魂，声音变哑",
        "en": "Loss of soul and a hoarse voice"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    },
    {
      "haircut": {
        "zh": "预见被争讼及死人",
        "en": "Disputes, litigation and encounters with the dead"
      },
      "washing": {
        "zh": "不好",
        "en": "Unfavorable"
      }
    }
  ]
}''';

  static Map<String, dynamic> defaults() =>
      jsonDecode(defaultJson) as Map<String, dynamic>;
  static bool valid(dynamic value) {
    if (value is! Map ||
        value['texts'] is! Map ||
        value['days'] is! List ||
        (value['days'] as List).length != 30) {
      return false;
    }
    if (value.containsKey('chinese_events') &&
        !ChineseCalendarEvents.valid(value['chinese_events'])) {
      return false;
    }
    bool pair(dynamic p) =>
        p is Map &&
        p['zh'] is String &&
        p['en'] is String &&
        (p['zh'] as String).length <= 10000 &&
        (p['en'] as String).length <= 10000;
    for (final key in (defaults()['texts'] as Map).keys) {
      if (!pair(value['texts'][key])) return false;
    }
    for (final day in value['days']) {
      if (day is! Map || !pair(day['haircut']) || !pair(day['washing'])) {
        return false;
      }
    }
    return true;
  }

  CalendarTraditions(dynamic value)
    : data = valid(value)
          ? jsonDecode(jsonEncode(value)) as Map<String, dynamic>
          : defaults() {
    // Upgrade only known old labels; preserve administrator-authored content.
    final texts = data['texts'] as Map;
    final current = defaults()['texts'] as Map;
    const legacy = {
      'heading': ['理发与洗头传统历俗'],
      'haircutLabel': ['理发(通则)', '理发（通则）'],
      'source': ['理发、洗头资料：用户提供，转述归于第司桑吉嘉措《白琉璃论》'],
      'specialWisdom': ['本月特别说明：剪发可以增长智慧（与每月二十五日通则并列保留）'],
      'caution': ['传统提醒：每年十一月初六、初七“大凶日，大事勿用”（所供原文）'],
    };
    for (final entry in legacy.entries) {
      if (entry.value.contains(texts[entry.key]['zh'])) {
        texts[entry.key]['zh'] = current[entry.key]['zh'];
      }
    }
    final handling = texts['handling']['zh'] as String;
    if (handling.startsWith('所附传统说明（原文）：')) {
      texts['handling']['zh'] = handling.substring('所附传统说明（原文）：'.length);
    }
  }
  final Map<String, dynamic> data;
  String text(String key, bool english) =>
      data['texts'][key][english ? 'en' : 'zh'] as String;
  String day(int day, String kind, bool english) =>
      data['days'][day - 1][kind][english ? 'en' : 'zh'] as String;
}
