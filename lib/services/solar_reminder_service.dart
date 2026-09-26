import 'dart:io';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/solar_times.dart';
import 'solar_location_service.dart';
import 'solar_time_service.dart';

class SolarReminderService with WidgetsBindingObserver {
  static final instance = SolarReminderService();
  final _plugin = FlutterLocalNotificationsPlugin();
  static final tappedPayload = ValueNotifier<String?>(null);
  Future<FlutterLocalNotificationsPlugin> notifications() async {
    await _initialize();
    return _plugin;
  }

  Future<void>? _ready;
  Future<void> _tail = Future.value();
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _backgroundRefresh();
  }

  void _backgroundRefresh() {
    unawaited(
      refresh().catchError((Object e) {
        debugPrint('Solar reminders refresh failed: ${e.runtimeType}');
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _backgroundRefresh();
  }

  Future<void> _initialize() => _ready ??= _init();
  Future<void> _init() async {
    SolarLocation.prepareZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_solar_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        windows: WindowsInitializationSettings(
          appName: '文殊计数器',
          appUserModelId: 'org.huideng.huideng_counter',
          guid: 'b55ef888-bc9e-49f2-8023-c6954f0c6a31',
        ),
      ),
      onDidReceiveNotificationResponse: (response) =>
          tappedPayload.value = response.payload,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'app_updates',
          '版本更新',
          description: '新版本发布通知',
        ),
      );
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'app_system',
          '系统通知',
          description: '账号和系统通知',
        ),
      );
    }
    if (launch?.didNotificationLaunchApp == true) {
      tappedPayload.value = launch?.notificationResponse?.payload;
    }
  }

  Future<void> remindChat(String room, String title, DateTime at) async {
    await _initialize();
    if (Platform.isAndroid) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .requestNotificationsPermission();
      if (granted != true) throw StateError('请允许通知权限');
    } else if (Platform.isIOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()!
          .requestPermissions(alert: true, sound: true, badge: false);
      if (granted != true) throw StateError('请允许通知权限');
    } else {
      throw StateError('此平台暂不支持定时提醒');
    }
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt('chat_reminder_next_id') ?? 100000;
    await prefs.setInt('chat_reminder_next_id', id + 1);
    await _plugin.zonedSchedule(
      id,
      '聊天提醒',
      '查看与$title的聊天',
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_reminders',
          '聊天提醒',
          channelDescription: '您设置的聊天定时提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'chat:$room',
    );
  }

  Future<SharedPreferences> _preferences() async {
    final prefs = await SharedPreferences.getInstance();
    // Preserve the user's choice when replacing the old ten-minute alarm.
    if (!prefs.containsKey('solar_remind_3')) {
      await prefs.setBool(
        'solar_remind_3',
        prefs.getBool('solar_remind_10') ?? false,
      );
    }
    return prefs;
  }

  Future<bool> enabled(int minutes) async =>
      (await _preferences()).getBool('solar_remind_$minutes') ?? false;
  Future<void> setEnabled(
    int minutes,
    bool value, {
    required bool english,
  }) async {
    if (value) {
      await _initialize();
      if (Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()!;
        if (await android.requestNotificationsPermission() != true) {
          throw StateError('notification_permission');
        }
        if (await android.canScheduleExactNotifications() != true &&
            await android.requestExactAlarmsPermission() != true) {
          throw StateError('alarm_permission');
        }
      } else if (Platform.isIOS) {
        if (await _plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()!
                .requestPermissions(alert: true, sound: true, badge: false) !=
            true) {
          throw StateError('notification_permission');
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('solar_remind_$minutes', value);
    await prefs.setBool('solar_reminder_english', english);
    try {
      await refresh();
    } catch (_) {
      if (value) await prefs.setBool('solar_remind_$minutes', false);
      rethrow;
    }
  }

  // Serialize scheduling so a slower refresh cannot undo a later toggle.
  Future<void> refresh() {
    final task = _tail.then((_) => _refresh());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> _refresh() async {
    final prefs = await _preferences();
    final thirty = prefs.getBool('solar_remind_30') ?? false;
    final three = prefs.getBool('solar_remind_3') ?? false;
    if (!thirty &&
        !three &&
        prefs.getBool('solar_reminders_scheduled') != true) {
      return;
    }
    await _initialize();
    // These IDs are reserved for solar reminders; never cancel chat notifications.
    for (var i = 0; i < 60; i++) {
      await _plugin.cancel(73000 + i);
    }
    await prefs.setBool('solar_reminders_scheduled', false);
    if (!thirty && !three) return;
    final location = await SolarLocationService().load();
    if (location == null) throw StateError('location_required');
    final english = prefs.getBool('solar_reminder_english') ?? false;
    final now = DateTime.now();
    final today = location.today(now);
    var count = 0;
    try {
      // Refill on startup/resume/location changes. 60 maximum also fits iOS.
      for (var day = 0; day < 30; day++) {
        final date = DateTime.utc(today.year, today.month, today.day + day);
        final times = const SolarTimeService().at(date, location);
        if (times.solarNoon == null) continue;
        for (final minutes in [if (thirty) 30, if (three) 3]) {
          final at = times.solarNoon!.subtract(Duration(minutes: minutes));
          if (!at.isAfter(now)) continue;
          await _plugin.zonedSchedule(
            73000 + day * 2 + (minutes == 30 ? 0 : 1),
            english ? 'Solar noon reminder' : '日中提醒',
            english
                ? 'Solar noon in $minutes minutes (${times.clock(times.solarNoon)}).'
                : '距当地日中还有$minutes分钟（日中 ${times.clock(times.solarNoon)}），请及时完成进食。',
            tz.TZDateTime.from(at, tz.UTC),
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'solar_noon',
                '日中提醒',
                channelDescription: '日中前的本地提醒',
                importance: Importance.high,
                priority: Priority.high,
              ),
              iOS: DarwinNotificationDetails(),
              windows: WindowsNotificationDetails(),
            ),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          );
          count++;
        }
      }
      await prefs.setBool('solar_reminders_scheduled', count > 0);
    } catch (_) {
      for (var i = 0; i < 60; i++) {
        await _plugin.cancel(73000 + i);
      }
      rethrow;
    }
  }
}
