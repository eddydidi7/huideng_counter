import 'package:nrel_spa/nrel_spa.dart';
import '../domain/solar_times.dart';

class SolarTimeService {
  const SolarTimeService();
  SolarTimes calculate({
    required DateTime date,
    required double latitude,
    required double longitude,
    required Duration utcOffset,
  }) {
    if (!latitude.isFinite ||
        latitude.abs() > 90 ||
        !longitude.isFinite ||
        longitude.abs() > 180 ||
        utcOffset.inMinutes.abs() > 14 * 60) {
      throw ArgumentError('Invalid solar location / offset');
    }
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final result = getSpa(
      key,
      latitude,
      longitude,
      utcOffset.inMinutes / 60,
      customAngles: const [96.0],
    );
    DateTime? instant(double hours) => !hours.isFinite
        ? null
        : DateTime.utc(
            date.year,
            date.month,
            date.day,
          ).add(Duration(seconds: (hours * 3600).round())).subtract(utcOffset);
    return SolarTimes(
      date: date,
      latitude: latitude,
      longitude: longitude,
      utcOffset: utcOffset,
      civilDawn: result.angles.isEmpty
          ? null
          : instant(result.angles.first.sunrise),
      sunrise: instant(result.sunrise),
      solarNoon: instant(result.solarNoon),
    );
  }

  SolarTimes at(DateTime date, SolarLocation location) => calculate(
    date: date,
    latitude: location.latitude,
    longitude: location.longitude,
    utcOffset: location.offsetFor(date),
  );
}
