import 'dart:async';
import 'package:flutter/widgets.dart';
import '../data/repositories/home_message_repository.dart';

class HomeMessageController extends ChangeNotifier with WidgetsBindingObserver {
  final HomeMessageRepository repository;
  Map<String, dynamic> value = {};
  bool _busy = false, _disposed = false, _loadingCache = true;
  Timer? _timer;
  HomeMessageController(this.repository);

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
      // Offline, missing table, or server failure: retain the last good quote.
    } finally {
      _busy = false;
    }
  }

  String body(bool english) =>
      value[english ? 'body_en' : 'body_zh'] as String? ?? '';
  String source(bool english) =>
      value[english ? 'source_en' : 'source_zh'] as String? ?? '';

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
