import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/app_release.dart';

void main() {
  Map<String, dynamic> row() => {
    'version_code': 75,
    'version_name': '1.0.2',
    'apk_size': 100,
    'download_url': 'https://example.test/app.apk',
    'sha256': 'a' * 64,
    'release_notes': '测试',
    'published_at': '2026-01-01T00:00:00Z',
  };
  test('versionCode and minimum gate, not versionName ordering', () {
    final release = AppRelease({...row(), 'minimum_version_code': 70});
    expect(release.requiredFor(69), true);
    expect(release.requiredFor(70), false);
    expect(release.requiredFor(75), false);
    expect(AppRelease({...row(), 'force_update': true}).requiredFor(74), true);
  });
  test('backwards compatible policies and invalid metadata rejected', () {
    final release = AppRelease(row());
    expect(
      release.startupCheck && release.promptEnabled && release.enabled,
      true,
    );
    expect(release.autoDownload, false);
    expect(release.wifiOnly, true);
    expect(release.shouldPromptFor(74), true);
    expect(release.shouldPromptFor(75), false);
    for (final field in ['updates_enabled', 'prompt_enabled', 'startup_check']) {
      expect(AppRelease({...row(), field: false}).shouldPromptFor(74), false);
    }
    expect(
      () => AppRelease({...row(), 'minimum_version_code': 76}),
      throwsFormatException,
    );
    expect(
      () =>
          AppRelease({...row(), 'download_url': 'http://example.test/app.apk'}),
      throwsFormatException,
    );
  });
}
