import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String guestDeviceNickname(String brand, String model) {
  final cleanBrand = brand.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  final cleanModel = model.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  final name = cleanModel.toLowerCase().contains(cleanBrand.toLowerCase())
      ? cleanModel
      : '$cleanBrand $cleanModel'.trim();
  return String.fromCharCodes((name.isEmpty ? '手机学友' : name).runes.take(40));
}

class ChatGuestSession {
  static final _pending = Expando<Future<void>>();
  static Future<void> ensure(SupabaseClient client) {
    if (client.auth.currentUser != null) return Future.value();
    return _pending[client] ??= _create(
      client,
    ).whenComplete(() => _pending[client] = null);
  }

  static Future<void> _create(SupabaseClient client) async {
    var nickname = '手机学友';
    try {
      final info = DeviceInfoPlugin();
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final data = await info.androidInfo;
        nickname = guestDeviceNickname(data.manufacturer, data.model);
      } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        final data = await info.iosInfo;
        nickname = guestDeviceNickname(
          '',
          data.modelName.isNotEmpty ? data.modelName : data.model,
        );
      } else {
        nickname = kIsWeb ? '网页学友' : '电脑学友';
      }
    } catch (_) {
      /* A model lookup failure must not prevent guest chat. */
    }
    // Another sign-in may have completed while reading the device model.
    if (client.auth.currentUser != null) return;
    await client.auth.signInAnonymously(
      data: {'chat_device_nickname': nickname},
    );
  }
}
