import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CounterHaptics {
  static const channel = MethodChannel('org.huideng.counter/haptics');
  static Future<bool> pulse({required bool enabled}) async {
    if (!enabled) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await channel.invokeMethod<bool>('count') ?? false;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await HapticFeedback.mediumImpact();
        return true;
      }
    } catch (_) {
      // Feedback must never turn an already saved count into a failed count.
    }
    return false;
  }
}
