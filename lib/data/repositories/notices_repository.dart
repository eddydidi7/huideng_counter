import '../local/home_message_cache.dart';
import '../remote/notices_remote.dart';

class NoticesRepository {
  final HomeMessageCache cache;
  NoticesRemote? remote;
  NoticesRepository(this.cache);
  Future<Map<String, dynamic>?> cached() => cache.read();

  Future<Map<String, dynamic>> refresh() async {
    final service = remote;
    if (service == null) throw StateError('Content service unavailable');
    // A successful empty response means removed: clear the cached configuration.
    final value = await service.fetch();
    try {
      await cache.write(value);
    } catch (_) {
      // Storage failure must not prevent displaying a valid remote response.
    }
    return value;
  }
}
