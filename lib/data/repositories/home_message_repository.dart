import '../local/home_message_cache.dart';
import '../remote/home_message_remote.dart';

class HomeMessageRepository {
  final HomeMessageCache cache;
  HomeMessageRemote? remote;
  HomeMessageRepository(this.cache);
  Future<Map<String, dynamic>?> cached() => cache.read();

  Future<Map<String, dynamic>> refresh() async {
    final service = remote;
    if (service == null) throw StateError('Content service unavailable');
    // A successful empty response means unpublished: clear the cached quote.
    final value = await service.fetch() ?? <String, dynamic>{};
    try {
      await cache.write(value);
    } catch (_) {
      // Storage failure must not prevent displaying a valid remote response.
    }
    return value;
  }
}
