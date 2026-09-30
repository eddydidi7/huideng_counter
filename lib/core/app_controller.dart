import 'package:flutter/widgets.dart';
import '../domain/models.dart';
import 'cloud_controller.dart';
import 'home_message_controller.dart';
import 'app_links_controller.dart';
import 'notices_controller.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  CounterRepository repository;
  GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  CloudController? cloud;
  HomeMessageController? homeMessage;
  NoticesController? notices;
  AppLinksController? _appLinks;
  AppLinksController? get appLinks => _appLinks;
  set appLinks(AppLinksController? next) {
    _appLinks?.removeListener(notifyListeners);
    _appLinks = next;
    next?.addListener(notifyListeners);
  }

  String scopeId = 'guest';
  Future<void> switchRepository(CounterRepository next, String scope) async {
    navigatorKey = GlobalKey<NavigatorState>();
    repository = next;
    scopeId = scope;
    projects = [];
    preferences = {};
    await reload();
  }

  AppController(this.repository) {
    WidgetsBinding.instance.addObserver(this);
  }
  List<CounterProject> projects = [];
  Map<String, String> preferences = {};
  String get languageMode =>
      const ['zh', 'en'].contains(preferences['language'])
      ? preferences['language']!
      : 'system';
  bool get english =>
      languageMode == 'en' ||
      (languageMode == 'system' &&
          WidgetsBinding.instance.platformDispatcher.locale.languageCode !=
              'zh');
  @override
  void didChangeLocales(List<Locale>? locales) {
    if (languageMode == 'system') notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appLinks?.removeListener(notifyListeners);
    super.dispose();
  }

  String get calendarUrl =>
      appLinks?.calendarUrl ??
      preferences['calendarUrl'] ??
      'https://zangli.org/';
  String get forumUrl =>
      appLinks?.forumUrl ??
      preferences['forumUrl'] ??
      'https://bodhi-culture.com/Article/question';
  String get colorPreference =>
      const ['light', 'dark'].contains(preferences['colorPreference'])
      ? preferences['colorPreference']!
      : 'system';
  String? get offeringUrl => appLinks?.offeringUrl;
  Map<String, dynamic> get aboutContent =>
      appLinks?.aboutContent ??
      {
        'email': 'eddydid@gmail.com',
        'qq': '79576743',
        'text_zh': '',
        'text_en': '',
        'images': <String>[],
      };
  bool get haptics => preferences['haptics'] != 'false';
  String get windowsDisplaySize =>
      const [
        'small',
        'standard',
        'large',
        'extraLarge',
      ].contains(preferences['windowsDisplaySize'])
      ? preferences['windowsDisplaySize']!
      : 'large';
  String get sunriseUrl =>
      appLinks?.sunriseUrl ??
      'https://www.daysfromdate.com/zh-cn/sunrise/cn?utm_source=chatgpt.com';
  String text(String zh, String en) => english ? en : zh;
  Future<void> reload() async {
    final current = repository;
    final items = await current.projects();
    final settings = await current.settings();
    if (!identical(current, repository)) return;
    projects = items;
    preferences = settings;
    notifyListeners();
  }

  Future<void> set(String key, String value) async {
    await repository.saveSetting(key, value);
    preferences[key] = value;
    notifyListeners();
  }
}
