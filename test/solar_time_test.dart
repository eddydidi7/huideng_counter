import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/solar_time_service.dart';
import 'package:huideng_counter/domain/solar_times.dart';

void main() {
  const service = SolarTimeService();
  final fixtures =
      jsonDecode(File('test/fixtures/solar_noaa.json').readAsStringSync())
          as Map;
  for (final row in fixtures['rows'] as List) {
    test('Independent NOAA comparison ${row['name']} ${row['date']}', () {
      final date = DateTime.parse(row['date'] as String);
      final offset = Duration(minutes: ((row['offset'] as num) * 60).round());
      final result = service.calculate(
        date: date,
        latitude: (row['lat'] as num).toDouble(),
        longitude: (row['lon'] as num).toDouble(),
        utcOffset: offset,
      );
      double minute(DateTime? time) {
        expect(time, isNotNull);
        final local = time!.add(offset);
        expect(
          [local.year, local.month, local.day],
          [date.year, date.month, date.day],
        );
        return local.hour * 60 + local.minute + local.second / 60;
      }

      // Different algorithms/refraction assumptions; allow 2 minutes.
      expect(minute(result.sunrise), closeTo(row['sunrise'] as num, 2));
      expect(minute(result.civilDawn), closeTo(row['civilDawn'] as num, 2));
      expect(minute(result.solarNoon), closeTo(row['solarNoon'] as num, 2));
      expect(result.civilDawn!.isBefore(result.sunrise!), isTrue);
      expect(result.sunrise!.isBefore(result.solarNoon!), isTrue);
    });
  }
  test('Auckland selected date uses DST, not current device offset', () {
    final location = SolarLocation(
      latitude: -36.8485,
      longitude: 174.7633,
      name: 'Auckland',
      updatedAt: DateTime.now(),
      savedOffsetMinutes: 720,
      timezoneId: 'Pacific/Auckland',
      manual: true,
    );
    expect(
      location.offsetFor(DateTime(2026, 9, 26)),
      const Duration(hours: 12),
    );
    expect(
      location.offsetFor(DateTime(2026, 9, 27)),
      const Duration(hours: 13),
    );
  });
  test(
    'Polar night/day return no sunrise without invalid displayed values',
    () {
      for (final date in [DateTime(2026, 6, 21), DateTime(2026, 12, 21)]) {
        final result = service.calculate(
          date: date,
          latitude: 78.2232,
          longitude: 15.6469,
          utcOffset: const Duration(hours: 1),
        );
        expect(result.sunrise, isNull);
        expect(result.solarNoon, isNotNull);
        expect(result.clock(result.sunrise), '—');
      }
    },
  );
  test('Invalid coordinates rejected', () {
    expect(
      () => service.calculate(
        date: DateTime(2026),
        latitude: double.nan,
        longitude: 0,
        utcOffset: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}
