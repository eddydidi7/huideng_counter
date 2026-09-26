import 'dart:async';
import 'package:flutter/widgets.dart';
import '../data/repositories/notices_repository.dart';

class NoticesController extends ChangeNotifier with WidgetsBindingObserver {
  final NoticesRepository repository;
  Map<String, dynamic> value = {};
  bool _busy = false, _disposed = false, _loadingCache = true;
  Timer? _timer;
  NoticesController(this.repository);

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      value = await repository.cached() ?? {};
      if (!_disposed) notifyListeners();
    } catch (_) {
      // An unavailable cache never blocks local counting.
    }
    _loadingCache = false;
    if (_disposed) return;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(refresh());
      }
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (_busy || _disposed || _loadingCache || repository.remote == null) {
      return;
    }
    _busy = true;
    try {
      final next = await repository.refresh();
      if (!_disposed) {
        value = next;
        notifyListeners();
      }
    } catch (_) {
      // Offline, missing table, or server failure: retain the last good configuration.
    } finally {
      _busy = false;
    }
  }

  List<Map<String, dynamic>> get items => (value['items'] as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
