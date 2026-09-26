import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import '../data/local/tibetan_calendar.dart';
import 'solar_page.dart';
import '../domain/calendar_observance_config.dart';
import '../domain/calendar_traditions.dart';
import '../domain/chinese_calendar_events.dart';
import 'calendar_traditions_panel.dart';

class TibetanCalendarPage extends StatefulWidget {
  final AppController app;
  final TibetanCalendar? calendar;
  const TibetanCalendarPage({super.key, required this.app, this.calendar});
  @override
  State<TibetanCalendarPage> createState() => _TibetanCalendarPageState();
}

class _TibetanCalendarPageState extends State<TibetanCalendarPage> {
  late final Future<TibetanCalendar> data = widget.calendar == null
      ? TibetanCalendar.load()
      : Future.value(widget.calendar!);
  DateTime selected = DateTime.now();
  bool openingSunrise = false;
  late DateTime month = DateTime(selected.year, selected.month);
  AppController get app => widget.app;
  String tr(String zh, String en) => app.text(zh, en);
  Future<void> openSunrise() async {
    if (openingSunrise) return;
    openingSunrise = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => SolarPage(app: app)),
      );
    } finally {
      if (mounted) setState(() => openingSunrise = false);
    }
  }

  @override
  void initState() {
    super.initState();
    app.addListener(refreshContent);
    app.appLinks?.refresh();
  }

  void refreshContent() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    app.removeListener(refreshContent);
    super.dispose();
  }

  CalendarObservanceConfig get observances {
    final traditions = app.appLinks?.value['calendar_traditions'];
    return CalendarObservanceConfig(
      traditions is Map ? traditions['observances'] : null,
    );
  }

  void move(int delta) => setState(() {
    month = DateTime(month.year, month.month + delta);
    selected = month;
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      titleSpacing: 8,
      title: Row(
        children: [
          Text(tr('藏历与日出', 'Calendar'), style: const TextStyle(fontSize: 17)),
          const SizedBox(width: 6),
          Expanded(
            child: FittedBox(
              // Fill the available header width, including on wider screens.
              fit: BoxFit.contain,
              alignment: Alignment.centerRight,
              child: Text(
                '${tr('公历：', 'Date: ')}${TibetanCalendar.key(selected)} ${tr(['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][selected.weekday - 1], ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][selected.weekday - 1])}',
                style: const TextStyle(fontSize: 18, color: Color(0xFF64B5F6)),
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline),
          tooltip: tr('数据来源', 'Data sources'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(tr('离线数据说明', 'Offline data')),
              content: SingleChildScrollView(
                child: SelectableText(
                  tr(
                    '覆盖：2025年1月1日—2026年12月31日。\n日期离线可用；殊胜日资料联网刷新，离线使用已缓存内容。\n\n日期：stonelf/zangli（MIT），来源于《藏历、公历、农历对照百年历书》。730天与 hnw/date-tibetan 的普巴历计算逐日比对，另核对 Ripa、Tushita 的8个节日日期。\n\n2027年的闰月命名存在来源差异，待核验后扩充。\n\n日月食：NASA目录，按北京时间归日，不代表当地可见。\n\n节日和共修日期请以所属寺院安排为准。',
                    'Coverage: 1 Jan 2025–31 Dec 2026. Dates work offline; observances refresh online and are cached.\n\nDates: stonelf/zangli (MIT), based on a published Tibetan/Gregorian almanac. All 730 days cross-checked with hnw/date-tibetan (Phugpa); 8 holiday anchors checked against Ripa and Tushita.\n\n2027 leap-month naming differs between sources and awaits verification.\n\nEclipses: NASA catalog; dates use China time and do not imply local visibility. Follow your monastery’s practice schedule.',
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('关闭', 'Close')),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF493039)
              : const Color(0xFFF6E3E6),
          child: ListTile(
            key: const ValueKey('calendar-sunrise-entry'),
            textColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFFF0B6BE)
                : const Color(0xFF8E3549),
            iconColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFFF0B6BE)
                : const Color(0xFF8E3549),
            contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 0, 8, 0),
            minLeadingWidth: 28,
            leading: const Icon(Icons.wb_sunny_outlined),
            title: LayoutBuilder(
              builder: (context, constraints) => FittedBox(
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
                child: Text(
                  tr('八关斋戒日出日中查询', 'Eight precepts · Sunrise & solar noon'),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize:
                        (Theme.of(context).textTheme.titleMedium?.fontSize ??
                            16) *
                        1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            dense: true,
            visualDensity: VisualDensity.compact,
            trailing: const Icon(Icons.chevron_right),
            onTap: openingSunrise ? null : openSunrise,
          ),
        ),
        Expanded(
          child: FutureBuilder<TibetanCalendar>(
            future: data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    tr(
                      '本地藏历数据读取失败，请重新打开。',
                      'Could not read the bundled calendar. Reopen this page.',
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final cal = snapshot.data!, row = cal.at(selected);
              final traditions = CalendarTraditions(
                app.appLinks?.value['calendar_traditions'],
              );
              final dayObservances = row == null
                  ? <Map<String, dynamic>>[]
                  : observances.at(row);
              final chineseEvent = ChineseCalendarEvents(
                traditions.data['chinese_events'],
              ).at(TibetanCalendar.key(selected), app.english);
              final offset = (month.weekday - 1) % 7,
                  count = DateTime(month.year, month.month + 1, 0).day;
              return ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  if (row != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                tr(
                                  '藏历：${row['yearName']}年 ${row['leapMonth'] == true ? '闰' : ''}${row['month']}月（${TibetanCalendar.monthNames[(row['month'] as int) - 1]}） ${TibetanCalendar.dayNames[(row['day'] as int) - 1]}',
                                  'Tibetan year ${row['year']} · ${row['leapMonth'] == true ? 'Leap ' : ''}${TibetanCalendar.monthNamesEn[(row['month'] as int) - 1]} · ${row['day']}',
                                ),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontSize:
                                          (Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.fontSize ??
                                              16) *
                                          2.25,
                                      color: const Color(0xFF64B5F6),
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (dayObservances.isNotEmpty) ...[
                                    TextSpan(
                                      text: tr('殊胜日：', 'Observances: '),
                                      style: const TextStyle(
                                        color: Color(0xFFE6BD54),
                                      ),
                                    ),
                                    TextSpan(
                                      text: dayObservances
                                          .map(
                                            (entry) => tr(
                                              entry['zh'] as String,
                                              entry['en'] as String,
                                            ),
                                          )
                                          .join(' · '),
                                    ),
                                    const TextSpan(text: ' ｜ '),
                                  ],
                                  TextSpan(
                                    text:
                                        '${traditions.text('haircutLabel', app.english)}：${traditions.day(row['day'] as int, 'haircut', app.english)}',
                                  ),
                                ],
                              ),
                              key: const ValueKey('calendar-day-summary'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (row['repeatIndex'] != 0)
                              Text(
                                tr(
                                  '重日：第 ${row['repeatIndex']} 次',
                                  'Repeated day: occurrence ${row['repeatIndex']}',
                                ),
                              ),
                            if ((row['skippedBefore'] as List).isNotEmpty)
                              Text(
                                tr(
                                  '此前缺日：${(row['skippedBefore'] as List).join('、')}（不另造公历日期）',
                                  'Skipped before this date: ${(row['skippedBefore'] as List).join(', ')}',
                                ),
                              ),
                            if (cal.eclipses[TibetanCalendar.key(selected)] !=
                                null)
                              Text(
                                '${eclipseName(cal.eclipses[TibetanCalendar.key(selected)] as String)} · ${tr('北京时间日期；不表示当地可见', 'China-time date; local visibility varies')}',
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (row == null)
                    Text(
                      tr(
                        '本地数据覆盖2025—2026年，请选择覆盖范围内的日期。',
                        'Offline coverage is 2025–2026. Select a date in this range.',
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        tooltip: tr('上一月', 'Previous month'),
                        onPressed: month.isAfter(DateTime(2025, 1))
                            ? () => move(-1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          '${month.year} / ${month.month}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          selected = DateTime.now();
                          month = DateTime(selected.year, selected.month);
                        }),
                        child: Text(tr('今天', 'Today')),
                      ),
                      IconButton(
                        tooltip: tr('下一月', 'Next month'),
                        onPressed: month.isBefore(DateTime(2026, 12))
                            ? () => move(1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < 7; i++)
                        Expanded(
                          child: Center(
                            child: Text(
                              tr(
                                ['一', '二', '三', '四', '五', '六', '日'][i],
                                ['M', 'T', 'W', 'T', 'F', 'S', 'S'][i],
                              ),
                              style: const TextStyle(fontSize: 17),
                            ),
                          ),
                        ),
                    ],
                  ),
                  GridView.builder(
                    key: const ValueKey('calendar-month-grid'),
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: offset + count,
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                          mainAxisExtent: MediaQuery.textScalerOf(context).scale(20) * 1.25 + MediaQuery.textScalerOf(context).scale(14) * 1.25 + MediaQuery.textScalerOf(context).scale(9) * 1.2 + 9,
                        ),
                    itemBuilder: (context, index) {
                      if (index < offset) return const SizedBox.shrink();
                      final date = DateTime(
                            month.year,
                            month.month,
                            index - offset + 1,
                          ),
                          r = cal.at(
                            DateTime(
                              month.year,
                              month.month,
                              index - offset + 1,
                            ),
                          );
                      final chosen =
                          TibetanCalendar.key(date) ==
                          TibetanCalendar.key(selected);
                      final auspicious =
                          r != null && observances.at(r).isNotEmpty;
                      final specialMonth =
                          r != null && observances.isHighlightedMonth(r);
                      final dark =
                          Theme.of(context).brightness == Brightness.dark;
                      final gold = dark
                          ? const Color(0xFFE6BD54)
                          : const Color(0xFF8A6000);
                      return InkWell(
                        onTap: () => setState(() => selected = date),
                        child: Container(
                          key: ValueKey(
                            'calendar-day-${TibetanCalendar.key(date)}',
                          ),
                          margin: const EdgeInsets.all(1),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: chosen
                                ? Border.all(
                                    color: const Color(0xFF64B5F6),
                                    width: 2,
                                  )
                                : null,
                            color: specialMonth
                                ? (dark
                                      ? const Color(0xFF493039)
                                      : const Color(0xFFF6E3E6))
                                : chosen
                                ? Theme.of(context).colorScheme.primaryContainer
                                : null,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '${date.day}',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: auspicious ? gold : null,
                                    fontWeight: auspicious
                                        ? FontWeight.w700
                                        : null,
                                  ),
                                ),
                                if (r != null)
                                  Text(
                                    tr(
                                      TibetanCalendar.dayNames[(r['day']
                                              as int) -
                                          1],
                                      '${r['month']}/${r['day']}',
                                    ),
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: auspicious ? gold : null,
                                    ),
                                  ),
                                if (auspicious)
                                  Icon(Icons.circle, size: 5, color: gold),
                                if (r != null && r['repeatIndex'] != 0)
                                  Text(
                                    tr(
                                      '重${r['repeatIndex']}',
                                      'R${r['repeatIndex']}',
                                    ),
                                    style: const TextStyle(fontSize: 9),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (row?['chineseLunar'] is Map)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(
                        chineseLunarLabel(
                          Map<String, dynamic>.from(row!['chineseLunar']),
                        ),
                        key: const ValueKey('calendar-chinese-lunar'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontSize:
                                  (Theme.of(
                                        context,
                                      ).textTheme.titleMedium?.fontSize ??
                                      16) *
                                  1.4,
                              color: const Color(0xFF64B5F6),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  if (row?['chineseLunar'] is Map && chineseEvent.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(
                        chineseEvent,
                        key: const ValueKey('calendar-chinese-events'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  const SizedBox(height: 2),
                  if (row != null) CalendarTraditionsPanel(app: app, row: row),
                  ExpansionTile(
                    title: Text(
                      tr(
                        observances.data['title_zh'],
                        observances.data['title_en'],
                      ),
                    ),
                    children: [
                      for (final entry in observances.entries.where(
                        (e) => e['enabled'] == true,
                      ))
                        ListTile(
                          dense: true,
                          title: Text(
                            '${entry['month'] == 0 ? tr('每月', 'Monthly ') : tr("${entry['month']}月", "Month ${entry['month']} / ")}${entry['day']}${entry['end_day'] == entry['day'] ? '' : "–${entry['end_day']}"}：${tr(entry['zh'], entry['en'])}',
                          ),
                          subtitle: entry['source'] == ''
                              ? null
                              : Text(entry['source']),
                          trailing: entry['url'] == ''
                              ? null
                              : IconButton(
                                  tooltip: tr('查看来源', 'View source'),
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  onPressed: () async {
                                    try {
                                      final opened = await launchUrl(
                                        Uri.parse(entry['url']),
                                        mode: LaunchMode.externalApplication,
                                      );
                                      if (!opened) {
                                        throw StateError(
                                          'Could not open source',
                                        );
                                      }
                                    } catch (_) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              tr(
                                                '无法打开来源链接',
                                                'Could not open source link',
                                              ),
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          tr(
                            observances.data['note_zh'],
                            observances.data['note_en'],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    tr(
                      '黄色：殊胜日 · 淡藏红：殊胜月 · 蓝框：选中日期',
                      'Gold: observance · Crimson tint: special month · Blue border: selected',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
  String chineseLunarLabel(Map<String, dynamic> lunar) {
    const stems = ['甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸'];
    const branches = [
      '子',
      '丑',
      '寅',
      '卯',
      '辰',
      '巳',
      '午',
      '未',
      '申',
      '酉',
      '戌',
      '亥',
    ];
    const animals = [
      '鼠',
      '牛',
      '虎',
      '兔',
      '龙',
      '蛇',
      '马',
      '羊',
      '猴',
      '鸡',
      '狗',
      '猪',
    ];
    const months = ['正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊'];
    final branch = (lunar['branch'] as int) - 1;
    return tr(
      '农历：${stems[(lunar['stem'] as int) - 1]}${branches[branch]}${animals[branch]}年 ${lunar['leapMonth'] == true ? '闰' : ''}${months[(lunar['month'] as int) - 1]}月${TibetanCalendar.dayNames[(lunar['day'] as int) - 1]}',
      'Chinese lunar: ${lunar['year']} · ${lunar['leapMonth'] == true ? 'Leap ' : ''}${lunar['month']}/${lunar['day']}',
    );
  }

  String festivalName(String key) => switch (key) {
    'losar' => tr('藏历新年', 'Losar'),
    'miracles' => tr('神变节', 'Chotrul Düchen'),
    'birth' => tr('释迦牟尼佛诞辰日', 'Birth of Shakyamuni Buddha'),
    'saga' => tr('萨嘎达瓦节 · 佛陀成道、涅槃日', 'Saga Dawa · Enlightenment & parinirvana'),
    'wheel' => tr('佛陀初转法轮日', 'Chökhor Düchen · First teaching'),
    _ => tr('天降日', 'Lhabab Düchen'),
  };
  String eclipseName(String key) => switch (key) {
    'lunarTotal' => tr('月全食', 'Total lunar eclipse'),
    'lunarPartial' => tr('月偏食', 'Partial lunar eclipse'),
    'solarTotal' => tr('日全食', 'Total solar eclipse'),
    'solarAnnular' => tr('日环食', 'Annular solar eclipse'),
    _ => tr('日偏食', 'Partial solar eclipse'),
  };
}
