import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/core/app_links_controller.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/remote/app_links_remote.dart';
import 'package:huideng_counter/data/repositories/app_links_repository.dart';

class StubRemote implements AppLinksRemote {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeLinks extends AppLinksRepository {
  Map<String, dynamic> next = {'calendar_url': 'https://zangli.org/'};
  bool fail = false;
  FakeLinks() : super(HomeMessageCache(cacheKey: 'app_links')) {
    remote = StubRemote();
  }
  @override
  Future<Map<String, dynamic>?> cached() async => {
    'forum_url': 'https://cached.example/',
    'sunrise_url': 'https://cached.example/sun',
  };
  @override
  Future<Map<String, dynamic>> refresh() async {
    if (fail) throw StateError('offline');
    return Map.of(next);
  }
}

void main() {
  test('rejects unsafe and malformed destinations', () {
    for (final value in [
      null,
      42,
      '',
      'http://example.com',
      'javascript:alert(1)',
      'https://user:pass@example.com',
      'https:///',
    ]) {
      expect(AppLinksController.validUrl(value), isNull);
    }
    expect(
      AppLinksController.validUrl('https://zangli.org/'),
      'https://zangli.org/',
    );
  });
  testWidgets('offline cache, remote refresh, failure retention and deletion', (
    tester,
  ) async {
    final repository = FakeLinks()..fail = true;
    final controller = AppLinksController(repository);
    await controller.initialize();
    expect(controller.forumUrl, 'https://cached.example/');
    expect(controller.sunriseUrl, 'https://cached.example/sun');
    repository.fail = false;
    repository.next['sunrise_url'] = 'https://changed.example/sun';
    await controller.refresh();
    expect(controller.calendarUrl, 'https://zangli.org/');
    expect(controller.sunriseUrl, 'https://changed.example/sun');
    repository.fail = true;
    await controller.refresh();
    expect(controller.calendarUrl, 'https://zangli.org/');
    repository.fail = false;
    repository.next = {};
    await controller.refresh();
    expect(controller.calendarUrl, isNull);
    expect(controller.sunriseUrl, isNull);
    controller.dispose();
  });
}
