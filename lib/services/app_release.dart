import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// android | windows | ios — matches app_releases.platform
/// (202609290077_app_releases_platform.sql). Anything else (macos, linux)
/// has no release track yet, so version checks are simply skipped there.
String? currentReleasePlatform() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  if (Platform.isIOS) return 'ios';
  return null;
}

class AppRelease {
  final int code, size;
  final String name, url, notes, hash;
  final DateTime publishedAt;
  final bool force;
  AppRelease(Map<String, dynamic> row)
    : code = (row['version_code'] as num).toInt(),
      size = (row['apk_size'] as num).toInt(),
      name = row['version_name'] as String,
      url = row['download_url'] as String,
      notes = row['release_notes'] as String,
      hash = row['sha256'] as String,
      publishedAt = DateTime.parse(row['published_at'] as String),
      force = row['force_update'] == true {
    final uri = Uri.parse(url);
    if (code < 1 ||
        size < 1 ||
        size > 524288000 ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('版本信息无效');
    }
  }

  /// [platform] must be one of currentReleasePlatform()'s values. Falls back
  /// to the pre-platform RPC only when explicitly asked (legacy Android
  /// callers that haven't been touched yet keep calling AppRelease.latest
  /// with no platform, below).
  static Future<AppRelease?> forPlatform(SupabaseClient client, String platform) async {
    final row = await client
        .rpc('latest_app_version', params: {'p_platform': platform})
        .timeout(const Duration(seconds: 20));
    return row == null ? null : AppRelease(Map<String, dynamic>.from(row as Map));
  }

  /// Legacy zero-arg call. The server-side function of the same name
  /// (202609290077) now delegates this to platform='android', so this stays
  /// correct for Android and should not be used for Windows.
  static Future<AppRelease?> latest(SupabaseClient client) async {
    final row = await client
        .rpc('latest_app_version')
        .timeout(const Duration(seconds: 20));
    return row == null
        ? null
        : AppRelease(Map<String, dynamic>.from(row as Map));
  }
}

/// Cross-platform "what build is actually running", via package_info_plus
/// (works on Windows too, reading windows/runner/Runner.rc's FLUTTER_VERSION_*
/// macros, which flutter build windows fills in from pubspec.yaml's version).
/// Android's own install still uses the native ApkFiles.channel for
/// installer-specific checks (cert/signature); this is only for comparing
/// against latest_app_version.
class InstalledApp {
  final String versionName;
  final int versionCode;
  const InstalledApp(this.versionName, this.versionCode);
  static Future<InstalledApp> current() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledApp(info.version, int.tryParse(info.buildNumber) ?? 0);
  }
}
