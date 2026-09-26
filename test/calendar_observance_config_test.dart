import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:huideng_counter/domain/calendar_observance_config.dart';
import 'package:huideng_counter/data/local/home_message_cache.dart';
import 'package:huideng_counter/data/remote/app_links_remote.dart';
import 'package:huideng_counter/data/repositories/app_links_repository.dart';

class MemoryCache extends HomeMessageCache {
  String? stored;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    stored = jsonEncode(value);
  }

  @override
  Future<Map<String, dynamic>?> read() async =>
      stored == null ? null : Map<String, dynamic>.from(jsonDecode(stored!));
}

class RemoteConfig implements AppLinksRemote {
  Map<String, dynamic> value = {};
  @override
  Future<Map<String, dynamic>?> fetch() async => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('month highlights are configurable and respect Tibetan months', () {
    final data = CalendarObservanceConfig.defaults();
    expect(
      CalendarObservanceConfig(data).isHighlightedMonth({'month': 4}),
      isTrue,
    );
    expect(
      CalendarObservanceConfig(data).isHighlightedMonth({'month': 8}),
      isFalse,
    );
    expect(
      CalendarObservanceConfig(
        data,
      ).isHighlightedMonth({'month': 4, 'leapMonth': true}),
      isFalse,
    );
    data['highlight_months'] = <int>[];
    expect(CalendarObservanceConfig.valid(data), isTrue);
    expect(
      CalendarObservanceConfig(data).isHighlightedMonth({'month': 4}),
      isFalse,
    );
    data['highlight_months'] = [13];
    expect(CalendarObservanceConfig.valid(data), isFalse);
  });
  test(
    'defaults and configured replacements, disable, ranges and repeated dates',
    () {
      final cfg = CalendarObservanceConfig.defaults();
      expect(CalendarObservanceConfig.valid(cfg), isTrue);
      expect((cfg['entries'] as List).length, 32);
      final entry = Map<String, dynamic>.from(cfg['entries'][0]);
      cfg['entries'] = [entry];
      entry.addAll({
        'month': 6,
        'day': 9,
        'end_day': 11,
        'zh': '后台新增',
        'repeat': 'first',
        'include_leap': false,
      });
      Map<String, dynamic> row(int d, {int repeat = 0, bool leap = false}) => {
        'month': 6,
        'day': d,
        'repeatIndex': repeat,
        'leapMonth': leap,
      };
      final c = CalendarObservanceConfig(cfg);
      expect(c.at(row(10)).single['zh'], '后台新增');
      expect(c.at(row(12)), isEmpty);
      expect(c.at(row(10, repeat: 2)), isEmpty);
      expect(c.at(row(10, leap: true)), isEmpty);
      entry['enabled'] = false;
      expect(CalendarObservanceConfig(cfg).at(row(10)), isEmpty);
      cfg['entries'] = [];
      expect(
        CalendarObservanceConfig(cfg).at(row(10)),
        isEmpty,
      ); // intentional empty != fallback
    },
  );
  test('reject malformed or unsafe configuration', () {
    for (final patch in [
      {'day': 0},
      {'month': 13},
      {'end_day': 7},
      {'day': 8.0},
      {'url': 'javascript:alert(1)'},
      {'url': 'https://user:pass@example.com'},
      {'enabled': 'true'},
      {'repeat': 'guess'},
      {'zh': ''},
    ]) {
      final v = CalendarObservanceConfig.defaults();
      (v['entries'][0] as Map).addAll(patch);
      expect(CalendarObservanceConfig.valid(v), isFalse, reason: '$patch');
    }
    final v = CalendarObservanceConfig.defaults();
    v['entries'].add(Map<String, dynamic>.from(v['entries'][0]));
    expect(CalendarObservanceConfig.valid(v), isFalse);
  });
  test(
    'last valid publication survives invalid update and reloads offline',
    () async {
      final remote = RemoteConfig();
      final cache = MemoryCache();
      final repository = AppLinksRepository(cache)..remote = remote;
      remote.value = {
        'calendar_traditions': {
          'observances': CalendarObservanceConfig.defaults(),
        },
      };
      await repository.refresh();
      remote.value = {
        'calendar_traditions': {
          'observances': {'schema': 99},
        },
      };
      await expectLater(repository.refresh(), throwsFormatException);
      final cached = await AppLinksRepository(cache).cached();
      expect(
        CalendarObservanceConfig.valid(
          cached!['calendar_traditions']['observances'],
        ),
        isTrue,
      );
    },
  );
}
