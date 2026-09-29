import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'generic_download.dart';

/// Matches the admin_broadcasts.file_size check in
/// 202609290076_admin_broadcast.sql.
const broadcastMaxFileBytes = 5368709120;

/// Files an admin pushed to this account (chat "文件传输助手"), backed by
/// broadcast_inbox_v1 (202609290076). Realtime keeps an open app current;
/// refresh() re-fetches the whole recent window (not an incremental cursor)
/// so a read/download mark made on another device shows up here too.
class BroadcastInbox extends ChangeNotifier {
  BroadcastInbox._();
  static final instance = BroadcastInbox._();

  SupabaseClient? _client;
  String? _user;
  RealtimeChannel? _channel;
  Timer? _timer;
  bool _busy = false;
  List<Map<String, dynamic>> items = [];
  bool available = true;

  int get unreadCount => items.where((r) => r['read_at'] == null).length;

  Future<void> ensure(SupabaseClient client) async {
    final user = client.auth.currentUser?.id;
    if (user == null) {
      await stop();
      return;
    }
    // Already watching this user: the realtime channel and the 30s timer
    // keep it current, so this no-ops instead of re-fetching every call
    // (content_link_host.dart's syncNotifications() calls ensure() each
    // second to pick up sign-in/out, not to force a refresh).
    if (_client == client && _user == user) return;
    await stop();
    _client = client;
    _user = user;
    _channel = client
        .channel('broadcast-inbox:$user')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'admin_broadcast_recipients',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: user),
          callback: (_) => unawaited(refresh()),
        )
        .subscribe();
    // Realtime is the fast path; this is the offline-catch-up / reconnect net.
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(refresh()));
    }
    await refresh();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final client = _client, channel = _channel;
    _channel = null;
    if (client != null && channel != null) {
      try {
        await client.removeChannel(channel);
      } catch (_) {}
    }
    _client = null;
    _user = null;
    items = [];
  }

  Future<void> refresh() async {
    final client = _client, user = _user;
    if (client == null || user == null || _busy) return;
    _busy = true;
    try {
      final result = await client
          .rpc('broadcast_inbox_v1', params: {'p_action': 'list', 'p_data': {'limit': 200}})
          .timeout(const Duration(seconds: 20));
      final rows = [for (final r in (result?['items'] as List? ?? [])) Map<String, dynamic>.from(r as Map)];
      items = rows;
      available = true;
      debugPrint('[FILE_RECEIVE] inbox refreshed user_id=$user count=${rows.length} unread=$unreadCount');
    } catch (e) {
      available = !(e is PostgrestException && const ['PGRST202', '42883'].contains(e.code));
      debugPrint('[FILE_RECEIVE] inbox refresh failed: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> markRead(String broadcastId) async {
    final client = _client;
    final idx = items.indexWhere((r) => r['broadcast_id'] == broadcastId);
    if (idx != -1 && items[idx]['read_at'] == null) {
      items[idx] = {...items[idx], 'read_at': DateTime.now().toUtc().toIso8601String()};
      notifyListeners();
    }
    if (client == null) return;
    try {
      await client.rpc('broadcast_inbox_v1', params: {'p_action': 'mark_read', 'p_data': {'broadcast_id': broadcastId}});
    } catch (_) {}
  }

  Future<void> _markDownloaded(String broadcastId) async {
    final client = _client;
    final idx = items.indexWhere((r) => r['broadcast_id'] == broadcastId);
    if (idx != -1) {
      items[idx] = {...items[idx], 'downloaded_at': DateTime.now().toUtc().toIso8601String()};
      notifyListeners();
    }
    if (client == null) return;
    try {
      await client.rpc('broadcast_inbox_v1', params: {'p_action': 'mark_downloaded', 'p_data': {'broadcast_id': broadcastId}});
    } catch (_) {}
  }

  /// Downloads [item] (a row from [items]) to local storage and returns the
  /// saved path. Reuses the existing local copy when size (and, if present,
  /// sha256) still match, so a re-tap after a completed download is free.
  Future<String> download(Map<String, dynamic> item, {void Function(double)? onProgress}) async {
    final client = _client;
    if (client == null) throw StateError('login_required');
    final broadcastId = item['broadcast_id'] as String;
    final storagePath = item['storage_path'] as String?;
    final url = storagePath != null
        ? await client.storage.from('broadcast-files').createSignedUrl(storagePath, 300)
        : item['download_url'] as String;
    final path = await _downloadToFile(
      url,
      item['file_name'] as String,
      (item['file_size'] as num).toInt(),
      item['sha256'] as String?,
      onProgress ?? (_) {},
    );
    debugPrint('[FILE_RECEIVE] downloaded broadcast_id=$broadcastId path=$path');
    await _markDownloaded(broadcastId);
    return path;
  }

  Future<String> _downloadToFile(
    String url,
    String fileName,
    int size,
    String? sha256Hex,
    void Function(double) onProgress,
  ) async {
    final dir = await getApplicationSupportDirectory();
    final safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    return downloadFile(
      url: url,
      targetPath: p.join(dir.path, 'broadcast_files', safeName),
      size: size,
      sha256Hex: sha256Hex,
      maxBytes: broadcastMaxFileBytes,
      onProgress: onProgress,
    );
  }
}
