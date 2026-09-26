import 'dart:async';
import 'package:flutter/widgets.dart';
import '../data/repositories/app_links_repository.dart';

class AppLinksController extends ChangeNotifier with WidgetsBindingObserver {
  final AppLinksRepository repository;
  Map<String, dynamic> value = {};
  bool _busy = false, _disposed = false, _loadingCache = true;
  Timer? _timer;
  AppLinksController(this.repository);

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

  static String? validUrl(dynamic value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : null;
  }

  String? get calendarUrl => validUrl(value['calendar_url']);
  String? get forumUrl => validUrl(value['forum_url']);
  String? get offeringUrl => validUrl(value['offering_url']);
  Map<String, dynamic>? get aboutContent => value['about_content'] is Map
      ? Map<String, dynamic>.from(value['about_content'])
      : null;
  List<Map<String, dynamic>> get publishedNotes =>
      (value['published_notes'] as List? ?? [])
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
  String? get sunriseUrl => validUrl(value['sunrise_url']);

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
