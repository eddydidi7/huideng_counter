import 'package:timezone/timezone.dart' as tz;
import 'solar_times.dart';

class SolarCity {
  const SolarCity(
    this.name,
    this.zh,
    this.country,
    this.countryZh,
    this.latitude,
    this.longitude,
    this.timezone,
  );
  final String name, zh, country, countryZh, timezone;
  final double latitude, longitude;
  String label(bool english) =>
      english ? '$name, $country' : '$zh · $countryZh';
  SolarLocation location({required bool english}) {
    SolarLocation.prepareZones();
    return SolarLocation(
      latitude: latitude,
      longitude: longitude,
      name: label(english),
      country: country,
      timezoneId: timezone,
      updatedAt: DateTime.now(),
      manual: true,
      savedOffsetMinutes: tz.TZDateTime.now(
        tz.getLocation(timezone),
      ).timeZoneOffset.inMinutes,
    );
  }
}

// GeoNames data (CC BY 4.0), retrieved through Open-Meteo on 2026-09-28.
// https://open-meteo.com/en/docs/geocoding-api / https://www.geonames.org/
const solarCities = [
  SolarCity(
    'Auckland',
    '奥克兰',
    'New Zealand',
    '新西兰',
    -36.84853,
    174.76349,
    'Pacific/Auckland',
  ),
  SolarCity(
    'Christchurch',
    '基督城',
    'New Zealand',
    '新西兰',
    -43.53333,
    172.63333,
    'Pacific/Auckland',
  ),
  SolarCity(
    'Melbourne',
    '墨尔本',
    'Australia',
    '澳大利亚',
    -37.814,
    144.96332,
    'Australia/Melbourne',
  ),
  SolarCity(
    'Sydney',
    '悉尼',
    'Australia',
    '澳大利亚',
    -33.86785,
    151.20732,
    'Australia/Sydney',
  ),
  SolarCity(
    'Chengdu',
    '成都',
    'China',
    '中国',
    30.66667,
    104.06667,
    'Asia/Shanghai',
  ),
  SolarCity('Lhasa', '拉萨', 'China', '中国', 29.65, 91.1, 'Asia/Shanghai'),
  SolarCity(
    'Shanghai',
    '上海',
    'China',
    '中国',
    31.22222,
    121.45806,
    'Asia/Shanghai',
  ),
  SolarCity(
    'Beijing',
    '北京',
    'China',
    '中国',
    39.9075,
    116.39723,
    'Asia/Shanghai',
  ),
  SolarCity(
    'Bangkok',
    '曼谷',
    'Thailand',
    '泰国',
    13.75398,
    100.50144,
    'Asia/Bangkok',
  ),
  SolarCity(
    'Kathmandu',
    '加德满都',
    'Nepal',
    '尼泊尔',
    27.70169,
    85.3206,
    'Asia/Kathmandu',
  ),
];

List<SolarCity> findSolarCities(String query, {String? country}) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
  return solarCities
      .where(
        (city) =>
            (country == null || country == city.country) &&
            terms.every(
              (t) => '${city.name} ${city.zh} ${city.country} ${city.countryZh}'
                  .toLowerCase()
                  .contains(t),
            ),
      )
      .toList();
}
