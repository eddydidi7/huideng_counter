import '../local/home_message_cache.dart';
import '../../domain/calendar_observance_config.dart';
import '../remote/app_links_remote.dart';

class AppLinksRepository {
  final HomeMessageCache cache;
  AppLinksRemote? remote;
  AppLinksRepository(this.cache);
  Future<Map<String, dynamic>?> cached() => cache.read();

  Future<Map<String, dynamic>> refresh() async {
    final service = remote;
    if (service == null) throw StateError('Content service unavailable');
    // A successful empty response means removed: clear the cached configuration.
    final value = await service.fetch() ?? <String, dynamic>{};
    final traditions = value['calendar_traditions'];
    if (traditions is Map &&
        traditions.containsKey('observances') &&
        !CalendarObservanceConfig.valid(traditions['observances'])) {
      throw const FormatException('Invalid calendar observances');
    }
    try {
      await cache.write(value);
    } catch (_) {
      // Storage failure must not prevent displaying a valid remote response.
    }
    return value;
  }
}
