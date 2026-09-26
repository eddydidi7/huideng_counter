import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/local/tibetan_calendar.dart';
import '../domain/calendar_observances.dart';
import '../domain/calendar_traditions.dart';

class CalendarTraditionsPanel extends StatelessWidget {
  const CalendarTraditionsPanel({
    super.key,
    required this.app,
    required this.row,
  });
  final AppController app;
  final Map<String, dynamic> row;
  String tr(String zh, String en) => app.text(zh, en);
  String text((String, String) pair) => tr(pair.$1, pair.$2);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => buildContent(context),
  );

  Widget buildContent(BuildContext context) {
    final config = CalendarTraditions(
      app.appLinks?.value['calendar_traditions'],
    );
    String label(String key) => config.text(key, app.english);
    final month = row['month'] as int, day = row['day'] as int;
    final special = CalendarObservances.specialHaircut(
      month,
      day,
      leapMonth: row['leapMonth'] == true,
    );
    return Card(
      key: const ValueKey('calendar-traditions'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${label('heading')}${label('source').isEmpty ? '' : ' ${label('source')}'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              tr(
                '藏历$month月${TibetanCalendar.dayNames[day - 1]}',
                'Tibetan month $month, day $day',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${label('haircutLabel')}：${config.day(day, 'haircut', app.english)}',
            ),
            if (special != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  label(month == 12 ? 'specialWisdom' : 'specialPurify'),
                ),
              ),
            Text(
              '${label('washingLabel')}：${config.day(day, 'washing', app.english)}',
            ),
            if (CalendarObservances.annualCaution(
              month,
              day,
              leapMonth: row['leapMonth'] == true,
            ))
              Text(label('caution')),
            const SizedBox(height: 4),
            Text(label('annual')),
            const SizedBox(height: 4),
            Text(label('infant'), style: Theme.of(context).textTheme.bodySmall),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(label('tableTitle')),
              children: [
                for (var d = 1; d <= 30; d++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${tr(TibetanCalendar.dayNames[d - 1], 'Day $d')} · ${label('haircutLabel')}：${config.day(d, 'haircut', app.english)}\n${label('washingLabel')}：${config.day(d, 'washing', app.english)}',
                      ),
                    ),
                  ),
                Text(label('tableAnnual')),
                const SizedBox(height: 12),
                SelectableText(label('handling')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
