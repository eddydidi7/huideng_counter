import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/domain/solar_cities.dart';
import 'package:huideng_counter/domain/solar_times.dart';
import 'package:huideng_counter/services/solar_location_service.dart';
import 'package:huideng_counter/services/solar_time_service.dart';

void main() {
  test('all requested cities searchable offline in English and Chinese', () {
    for (final name in [
      'Auckland',
      'Christchurch',
      'Melbourne',
      'Sydney',
      'Chengdu',
      'Lhasa',
      'Bangkok',
      'Kathmandu',
    ]) {
      expect(findSolarCities(name).single.name, name);
    }
    expect(findSolarCities('拉萨').single.timezone, 'Asia/Shanghai');
    expect(findSolarCities('', country: 'New Zealand').length, 2);
    expect(findSolarCities('unlisted'), isEmpty);
  });
  test(
    'manual city, country, coordinates and timezone survive persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final source = SolarLocationService();
      final city = findSolarCities('Auckland').single.location(english: true);
      await source.save(city);
      final restored = (await source.load())!;
      expect(restored.manual, true);
      expect(restored.locationSource, 'manual');
      expect(restored.country, 'New Zealand');
      expect(restored.latitude, -36.84853);
      expect(restored.longitude, 174.76349);
      expect(restored.timezoneId, 'Pacific/Auckland');
      expect(restored.offsetFor(DateTime(2026, 1, 1)).inHours, 13);
      expect(restored.offsetFor(DateTime(2026, 7, 1)).inHours, 12);
      expect(SolarLocation.fromJson(city.toJson()).name, city.name);
    },
  );
  test(
    'remote city solar calculation uses city offset, including fractional zones',
    () {
      final lhasa = findSolarCities('Lhasa').single.location(english: true);
      final kathmandu = findSolarCities(
        'Kathmandu',
      ).single.location(english: true);
      final date = DateTime(2026, 9, 28);
      expect(lhasa.offsetFor(date).inMinutes, 480);
      expect(kathmandu.offsetFor(date).inMinutes, 345);
      final result = const SolarTimeService().at(date, lhasa);
      expect(result.utcOffset.inHours, 8);
      expect(result.sunrise, isNotNull);
      expect(result.clock(result.solarNoon).startsWith('13:'), true);
    },
  );
}
