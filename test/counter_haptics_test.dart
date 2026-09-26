import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/counter_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CounterHaptics.channel, null);
  });
  test(
    'disabled feedback never calls native vibrator; enabled uses count channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CounterHaptics.channel, (call) async {
            expect(call.method, 'count');
            calls++;
            return true;
          });
      expect(await CounterHaptics.pulse(enabled: false), false);
      expect(calls, 0);
      expect(await CounterHaptics.pulse(enabled: true), true);
      expect(calls, 1);
    },
  );
  test('native failures do not propagate into counter save queue', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CounterHaptics.channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });
    expect(await CounterHaptics.pulse(enabled: true), false);
  });
}
