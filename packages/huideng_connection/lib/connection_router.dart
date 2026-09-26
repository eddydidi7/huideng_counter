import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'signed_connection_config.dart';

class ConnectionRouter extends ChangeNotifier {
  ConnectionRouter({
    required this.canonical,
    required this.project,
    this.publicKey = '',
    this.sources = const [],
  });
  final Uri canonical;
  final String project, publicKey;
  final List<Uri> sources;
  SignedConnectionConfig? config;
  Uri? _active;
  SharedPreferences? _prefs;
  Future<void>? _refreshing;
  Timer? _timer, _expiry;
  DateTime? _lastRefresh;
  bool _disposed = false;
  String? _envelope;
  int _floor = 0;
  String? _floorPayload;
  String get cacheKey => 'connection.config.v1.$project';
  bool get configured => publicKey.isNotEmpty && sources.isNotEmpty;
  List<Uri> get origins =>
      config != null && config!.expiresAt.isAfter(DateTime.now().toUtc())
      ? config!.origins
      : [canonical];
  Uri get active => origins.contains(_active) ? _active! : origins.first;
  bool owns(Uri uri) =>
      uri.host == canonical.host &&
      (uri.hasPort ? uri.port : 443) == canonical.port &&
      ['https', 'wss'].contains(uri.scheme);
  Uri route(Uri uri) => owns(uri)
      ? uri.replace(
          host: active.host,
          port: active.hasPort ? active.port : null,
        )
      : uri;

  Future<void> initialize({bool refreshNow = true}) async {
    if (!configured) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      /* Cache unavailable; networking must still initialize. */
    }
    final stored = _prefs?.getString(cacheKey);
    if (stored != null) {
      try {
        final saved = jsonDecode(stored) as Map<String, dynamic>;
        final cachedEnvelope = saved['envelope'] as String;
        final trusted = await SignedConnectionConfig.verify(
          cachedEnvelope,
          publicKey: publicKey,
          project: project,
          now: DateTime.now().toUtc(),
          allowExpired: true,
        );
        _floor = trusted.version;
        _floorPayload = trusted.payload;
        if (trusted.expiresAt.isAfter(DateTime.now().toUtc())) {
          await apply(cachedEnvelope, persist: false);
        }
        final last = Uri.parse(saved['active'] as String);
        if (origins.contains(last)) _active = last;
      } catch (_) {
        /* Retain version floor, use baked-in origin. */
      }
    }
    _timer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(refresh()),
    );
    // Independent mirrors refresh in the background; local/offline startup never waits for them.
    if (refreshNow) unawaited(refresh());
  }

  Future<void> apply(String envelope, {bool persist = true}) async {
    final next = await SignedConnectionConfig.verify(
      envelope,
      publicKey: publicKey,
      project: project,
      now: DateTime.now().toUtc(),
      minimumVersion: _floor,
      currentPayload: _floorPayload,
    );
    if (_disposed) return;
    final previous = active;
    final previousVersion = config?.version ?? 0;
    _expiry?.cancel();
    _expiry = Timer(next.expiresAt.difference(DateTime.now().toUtc()), () {
      if (_disposed) return;
      config = null;
      _active = canonical;
      notifyListeners();
      unawaited(refresh());
    });
    config = next;
    _envelope = envelope;
    _floor = next.version;
    _floorPayload = next.payload;
    if (next.version > previousVersion || !origins.contains(_active))
      _active = origins.first;
    if (persist) {
      try {
        await _save();
      } catch (_) {
        /* Retain the verified configuration in memory. */
      }
    }
    if (!_disposed && previous != active) notifyListeners();
  }

  Future<void> _save() async {
    if (_envelope == null) return;
    await _prefs?.setString(
      cacheKey,
      jsonEncode({
        'version': _floor,
        'payload': _floorPayload,
        'envelope': _envelope,
        'active': active.toString(),
      }),
    );
  }

  void failed(Uri failedOrigin) {
    if (_disposed || failedOrigin.host != active.host || origins.length < 2) {
      return;
    }
    _active = origins[(origins.indexOf(active) + 1) % origins.length];
    unawaited(_save().catchError((Object _) {}));
    notifyListeners();
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (!configured || _disposed) return;
    final now = DateTime.now();
    if (_lastRefresh != null &&
        now.difference(_lastRefresh!) < const Duration(seconds: 30))
      return;
    _lastRefresh = now;
    for (final source in sources) {
      final client = http.Client();
      try {
        if (source.scheme != 'https' ||
            source.userInfo.isNotEmpty ||
            source.hasFragment) {
          continue;
        }
        final response = await client
            .send(http.Request('GET', source)..followRedirects = false)
            .timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) continue;
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 6),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 32768) {
            throw const FormatException('Oversized config');
          }
        }
        await apply(utf8.decode(bytes));
        return;
      } catch (_) {
        /* Try the next independent source without leaking tokens. */
      } finally {
        client.close();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _expiry?.cancel();
    super.dispose();
  }
}
