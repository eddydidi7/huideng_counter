import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/solar_times.dart';

class SolarLocationFailure implements Exception {
  const SolarLocationFailure(this.code);
  final String code;
}

class SolarLocationService {
  SolarLocationService({this.clientFactory});
  final http.Client Function()? clientFactory;
  static const nameCacheKey = 'solar_place_name_v1';
  static const cacheKey = 'solar_location_v1';
  static int _selectionRevision = 0;
  Future<SolarLocation?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(cacheKey);
    if (raw == null) return null;
    try {
      return SolarLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Solar cache invalid: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> save(SolarLocation location) async {
    _selectionRevision++;
    final ok = await (await SharedPreferences.getInstance()).setString(
      cacheKey,
      jsonEncode(location.toJson()),
    );
    if (!ok) throw const SolarLocationFailure('save');
  }

  Future<SolarLocation> refresh({
    SolarLocation? previous,
    bool explicit = false,
  }) async {
    final revision = _selectionRevision;
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const SolarLocationFailure('disabled');
    }
    var permission = await Geolocator.checkPermission();
    final prefs = await SharedPreferences.getInstance();
    if (permission == LocationPermission.denied &&
        (explicit || prefs.getBool('solar_permission_asked') != true)) {
      await prefs.setBool('solar_permission_asked', true);
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const SolarLocationFailure('permanent');
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      throw const SolarLocationFailure('denied');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 20),
      ),
    );
    if (!position.latitude.isFinite || !position.longitude.isFinite) {
      throw const SolarLocationFailure('unavailable');
    }
    SolarLocation? lastNamed;
    try {
      final raw = prefs.getString(nameCacheKey);
      if (raw != null) {
        lastNamed = SolarLocation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      /* Ignore a damaged name cache, not the GPS fix. */
    }
    final fresh = SolarLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      name: cachedName(
        lastNamed ?? previous,
        position.latitude,
        position.longitude,
      ),
      updatedAt: DateTime.now(),
      savedOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
    );
    // Commit GPS immediately. Geocoding must never delay solar calculations.
    if (revision == _selectionRevision) await save(fresh);
    return fresh;
  }

  static String cachedName(SolarLocation? previous, double lat, double lon) {
    if (previous == null ||
        previous.manual ||
        previous.name.trim().isEmpty ||
        DateTime.now().difference(previous.updatedAt).inDays > 30) {
      return '';
    }
    return Geolocator.distanceBetween(
              previous.latitude,
              previous.longitude,
              lat,
              lon,
            ) <
            1000
        ? previous.name
        : '';
  }

  /// Only call for the current device GPS fix, never a manually entered place.
  /// Native geocoder first, independent network provider as fallback.
  Future<String> resolveName(SolarLocation fix) async {
    if (fix.manual || DateTime.now().difference(fix.updatedAt).inMinutes >= 2) {
      return '';
    }
    try {
      final nativeName =
          await const MethodChannel('org.huideng.counter/location')
              .invokeMethod<String>('placeName', {
                'latitude': fix.latitude,
                'longitude': fix.longitude,
              })
              .timeout(const Duration(seconds: 8));
      if (nativeName != null && nativeName.trim().isNotEmpty) {
        return await rememberName(fix, nativeName.trim());
      }
      debugPrint('Solar geocoder: native returned no place');
    } catch (e) {
      debugPrint('Solar geocoder native failed: ${e.runtimeType}');
    }
    final client = clientFactory?.call() ?? http.Client();
    try {
      final response = await client
          .get(
            Uri.https('api.bigdatacloud.net', '/data/reverse-geocode-client', {
              'latitude': fix.latitude.toString(),
              'longitude': fix.longitude.toString(),
              'localityLanguage':
                  ui.PlatformDispatcher.instance.locale.languageCode,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('Solar geocoder fallback HTTP ${response.statusCode}');
        return '';
      }
      final name = parsePlace(
        jsonDecode(response.body) as Map<String, dynamic>,
        fix,
      );
      if (name.isNotEmpty) return await rememberName(fix, name);
      return '';
    } catch (e) {
      debugPrint('Solar geocoder fallback failed: ${e.runtimeType}');
      return '';
    } finally {
      client.close();
    }
  }

  Future<String> rememberName(SolarLocation fix, String name) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        nameCacheKey,
        jsonEncode({...fix.toJson(), 'name': name}),
      );
    } catch (e) {
      debugPrint('Solar place cache: ${e.runtimeType}');
    }
    return name;
  }

  static String parsePlace(Map<String, dynamic> data, SolarLocation fix) {
    // The provider can fall back to IP geolocation: never label GPS with an IP city.
    if (data['lookupSource'] != 'reverseGeocoding') return '';
    return ['locality', 'city', 'principalSubdivision', 'countryName']
        .map((key) => (data[key] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .join(', ');
  }
}
