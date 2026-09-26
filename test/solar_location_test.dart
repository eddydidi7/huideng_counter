import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/services/solar_location_service.dart';

class FakeLocator extends GeolocatorPlatform {
  bool enabled = true, allow = true;
  int requests = 0;
  LocationPermission permission = LocationPermission.denied;
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = allow
        ? LocationPermission.whileInUse
        : LocationPermission.denied;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => Position(
    longitude: 121.4737,
    latitude: 31.2304,
    timestamp: DateTime.now(),
    accuracy: 100,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLocator fake;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakeLocator();
    GeolocatorPlatform.instance = fake;
  });
  test(
    'First grant, restart reads persisted location, subsequent use does not request again',
    () async {
      final service = SolarLocationService();
      final first = await service.refresh();
      expect(fake.requests, 1);
      final cached = await SolarLocationService().load();
      expect(cached!.latitude, first.latitude);
      await service.refresh(previous: cached);
      expect(fake.requests, 1);
      fake.enabled = false;
      await expectLater(
        service.refresh(previous: cached),
        throwsA(isA<SolarLocationFailure>()),
      );
      expect((await service.load())!.latitude, first.latitude);
    },
  );
  test(
    'Permission denial does not repeatedly prompt on automatic opens',
    () async {
      fake.allow = false;
      final service = SolarLocationService();
      await expectLater(
        service.refresh(),
        throwsA(isA<SolarLocationFailure>()),
      );
      await expectLater(
        service.refresh(),
        throwsA(isA<SolarLocationFailure>()),
      );
      expect(fake.requests, 1);
      await expectLater(
        service.refresh(explicit: true),
        throwsA(isA<SolarLocationFailure>()),
      );
      expect(fake.requests, 2);
    },
  );
  test('Location disabled does not request permission', () async {
    fake.enabled = false;
    await expectLater(
      SolarLocationService().refresh(),
      throwsA(isA<SolarLocationFailure>()),
    );
    expect(fake.requests, 0);
  });
}
