import 'package:supabase_flutter/supabase_flutter.dart';

class AppRelease {
  final int code, size, minimumCode;
  final String name, url, notes, hash;
  final DateTime publishedAt;
  final bool force;
  final bool enabled, promptEnabled, startupCheck, autoDownload, wifiOnly;
  bool shouldPromptFor(int installed) =>
      enabled && promptEnabled && startupCheck && code > installed;
  bool requiredFor(int installed) =>
      code > installed && (force || installed < minimumCode);
  AppRelease(Map<String, dynamic> row)
    : code = (row['version_code'] as num).toInt(),
      size = (row['apk_size'] as num).toInt(),
      minimumCode = (row['minimum_version_code'] as num? ?? 0).toInt(),
      enabled = row['updates_enabled'] != false,
      promptEnabled = row['prompt_enabled'] != false,
      startupCheck = row['startup_check'] != false,
      autoDownload = row['auto_download'] == true,
      wifiOnly = row['wifi_only'] != false,
      name = row['version_name'] as String,
      url = row['download_url'] as String,
      notes = row['release_notes'] as String,
      hash = row['sha256'] as String,
      publishedAt = DateTime.parse(row['published_at'] as String),
      force = row['force_update'] == true {
    final uri = Uri.parse(url);
    if (code < 1 ||
        minimumCode < 0 ||
        minimumCode > code ||
        size < 1 ||
        size > 524288000 ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('版本信息无效');
    }
  }
  static Future<AppRelease?> latest(SupabaseClient client) async {
    final row = await client
        .rpc('latest_app_version')
        .timeout(const Duration(seconds: 20));
    return row == null
        ? null
        : AppRelease(Map<String, dynamic>.from(row as Map));
  }
}
