import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/adaptive_action_bar.dart';
import 'package:huideng_counter/presentation/forum_page.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/solar_times.dart';
import 'package:huideng_counter/services/solar_location_service.dart';
import 'forum_test.dart' show UnusedCounter;

void main() {
  for (final width in [320.0, 360.0, 412.0, 480.0]) {
    for (final scale in [1.0, 1.6, 2.0]) {
      testWidgets(
        'reading header fits $width at $scale, actions remain touchable',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: AdaptiveActionBar(
                    menuIndex: 3,
                    actions: [
                      '阅读',
                      '发红书',
                      '聊天',
                      '完成',
                    ].map((v) => BarAction(v, () => calls++)).toList(),
                    menu: IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                ),
              ),
            ),
          );
          for (final label in ['阅读', '发红书', '聊天', '完成']) {
            await tester.tap(find.text(label));
            final rect = tester.getRect(find.widgetWithText(TextButton, label));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.right, lessThanOrEqualTo(width + .1));
          }
          expect(calls, 4);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  test(
    'native unavailable uses current-GPS fallback and preserves cached name on failure',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.huideng.counter/location'),
            (_) async => '',
          );
      SharedPreferences.setMockInitialValues({});
      final fix = SolarLocation(
        latitude: -36.8793,
        longitude: 174.9241,
        name: '',
        updatedAt: DateTime.now(),
        savedOffsetMinutes: 720,
      );
      final service = SolarLocationService(
        clientFactory: () => MockClient((request) async {
          expect(request.url.queryParameters['latitude'], '-36.8793');
          return http.Response(
            jsonEncode({
              'lookupSource': 'reverseGeocoding',
              'locality': 'Mellons Bay',
              'city': 'Auckland',
              'countryName': 'New Zealand',
            }),
            200,
          );
        }),
      );
      expect(
        await service.resolveName(fix),
        'Mellons Bay, Auckland, New Zealand',
      );
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(SolarLocationService.nameCacheKey);
      final failed = SolarLocationService(
        clientFactory: () => MockClient((_) async => http.Response('', 503)),
      );
      expect(await failed.resolveName(fix), '');
      expect(prefs.getString(SolarLocationService.nameCacheKey), saved);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('org.huideng.counter/location'),
            null,
          );
    },
  );
  testWidgets('untitled text uses seven lines and short text is not padded', (
    tester,
  ) async {
    final app = AppController(UnusedCounter());
    Future<double> show(String body) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 180,
                  child: ForumPostCard(
                    app: app,
                    row: {
                      'id': 'test',
                      'title': '',
                      'body': body,
                      'image_urls': [],
                    },
                    listMode: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text(body));
      expect(text.maxLines, 7);
      expect(text.overflow, TextOverflow.ellipsis);
      return tester.getSize(find.byType(ForumPostCard)).height;
    }

    final short = await show('一行正文');
    final long = await show(List.filled(30, '足够长的正文供预览。').join());
    expect(long, greaterThan(short));
    expect(tester.takeException(), isNull);
    app.dispose();
  });
  test(
    'geocoder cache requires nearby nonempty recent place; IP fallback rejected',
    () {
      final fix = SolarLocation(
        latitude: -36.8793,
        longitude: 174.9241,
        name: 'Mellons Bay',
        updatedAt: DateTime.now(),
        savedOffsetMinutes: 720,
      );
      expect(
        SolarLocationService.cachedName(fix, -36.8794, 174.9241),
        'Mellons Bay',
      );
      expect(SolarLocationService.cachedName(fix, 31, 121), '');
      expect(
        SolarLocationService.parsePlace({
          'lookupSource': 'ipGeolocation',
          'city': 'Wrong',
        }, fix),
        '',
      );
      expect(
        SolarLocationService.parsePlace({
          'lookupSource': 'reverseGeocoding',
          'locality': 'Mellons Bay',
          'city': 'Auckland',
          'principalSubdivision': 'Auckland',
          'countryName': 'New Zealand',
        }, fix),
        'Mellons Bay, Auckland, New Zealand',
      );
    },
  );
}
