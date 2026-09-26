import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class SolarLocation {
  const SolarLocation({
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.updatedAt,
    required this.savedOffsetMinutes,
    this.timezoneId,
    this.manual = false,
  });
  final double latitude, longitude;
  final String name;
  final DateTime updatedAt;
  final int savedOffsetMinutes;
  final String? timezoneId;
  final bool manual;
  static bool _zonesReady = false;
  static void prepareZones() {
    if (!_zonesReady) {
      tz_data.initializeTimeZones();
      _zonesReady = true;
    }
  }

  Duration offsetFor(DateTime date) {
    if (timezoneId != null) {
      prepareZones();
      return tz.TZDateTime(
        tz.getLocation(timezoneId!),
        date.year,
        date.month,
        date.day,
        12,
      ).timeZoneOffset;
    }
    // Use the selected day's device offset, not today's offset (DST).
    return DateTime(date.year, date.month, date.day, 12).timeZoneOffset;
  }

  DateTime today([DateTime? now]) {
    final instant = now ?? DateTime.now();
    if (timezoneId == null) return instant.toLocal();
    prepareZones();
    return tz.TZDateTime.from(instant, tz.getLocation(timezoneId!));
  }

  Map<String, dynamic> toJson() => {
    'solar_latitude': latitude,
    'solar_longitude': longitude,
    'solar_location_name': name,
    'solar_timezone_offset': savedOffsetMinutes,
    'solar_location_updated_at': updatedAt.toUtc().toIso8601String(),
    'timezone_id': timezoneId,
    'manual': manual,
  };
  factory SolarLocation.fromJson(Map<String, dynamic> j) {
    final lat = (j['solar_latitude'] as num).toDouble();
    final lon = (j['solar_longitude'] as num).toDouble();
    if (!lat.isFinite || lat.abs() > 90 || !lon.isFinite || lon.abs() > 180) {
      throw const FormatException('Invalid coordinates');
    }
    final zone = j['timezone_id'] as String?;
    if (zone != null) {
      prepareZones();
      tz.getLocation(zone);
    }
    return SolarLocation(
      latitude: lat,
      longitude: lon,
      name: j['solar_location_name'] as String? ?? '',
      updatedAt: DateTime.parse(j['solar_location_updated_at'] as String),
      savedOffsetMinutes: (j['solar_timezone_offset'] as num).toInt(),
      timezoneId: zone,
      manual: j['manual'] == true,
    );
  }
}

class SolarTimes {
  const SolarTimes({
    required this.date,
    required this.latitude,
    required this.longitude,
    required this.utcOffset,
    required this.civilDawn,
    required this.sunrise,
    required this.solarNoon,
  });
  final DateTime date;
  final double latitude, longitude;
  final Duration utcOffset;
  // Absolute UTC instants. UI formats using utcOffset, never device.toLocal()
  // for a manually selected location in a different timezone.
  final DateTime? civilDawn, sunrise, solarNoon;
  String clock(DateTime? value) {
    if (value == null) return '—';
    final local = value.toUtc().add(utcOffset);
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
