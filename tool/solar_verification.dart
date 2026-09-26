import 'dart:convert';
import 'dart:io';
import 'package:huideng_counter/services/solar_time_service.dart';

void main() {
  final data =
      jsonDecode(File('test/fixtures/solar_noaa.json').readAsStringSync())
          as Map;
  double maxError = 0;
  for (final row in data['rows'] as List) {
    final off = Duration(minutes: ((row['offset'] as num) * 60).round());
    final times = const SolarTimeService().calculate(
      date: DateTime.parse(row['date']),
      latitude: row['lat'],
      longitude: row['lon'],
      utcOffset: off,
    );
    final errors = <double>[];
    for (final entry in {
      'civilDawn': times.civilDawn,
      'sunrise': times.sunrise,
      'solarNoon': times.solarNoon,
    }.entries) {
      final local = entry.value!.add(off);
      final seconds = local.hour * 3600 + local.minute * 60 + local.second;
      final error = (seconds - (row[entry.key] as num) * 60).abs().toDouble();
      errors.add(error);
      if (error > maxError) maxError = error;
    }
    stdout.writeln(
      '${row['name']} ${row['date']}: dawn=${times.clock(times.civilDawn)} sunrise=${times.clock(times.sunrise)} noon=${times.clock(times.solarNoon)} | errorSeconds=$errors',
    );
  }
  stdout.writeln('Maximum error seconds: $maxError');
}
