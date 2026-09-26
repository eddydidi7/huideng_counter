import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../core/app_controller.dart';
import '../services/chat_notification_settings.dart';
import '../services/solar_reminder_service.dart';

class ChatNotificationSettingsPage extends StatefulWidget {
  const ChatNotificationSettingsPage({super.key, required this.app});
  final AppController app;
  @override
  State<ChatNotificationSettingsPage> createState() =>
      _ChatNotificationSettingsPageState();
}

class _ChatNotificationSettingsPageState
    extends State<ChatNotificationSettingsPage> {
  static const bridge = MethodChannel('org.huideng.counter/notifications');
  ChatNotificationSettings? settings;
  late final String user =
      widget.app.cloud?.client?.auth.currentUser?.id ?? 'local';
  String tr(String a, String b) => widget.app.text(a, b);
  @override
  void initState() {
    super.initState();
    ChatNotificationSettings.load(user).then((s) {
      if (mounted) setState(() => settings = s);
    });
  }

  Future<void> change(VoidCallback apply) async {
    setState(apply);
    try {
      await settings!.save(user);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('设置未保存，请重试', 'Settings were not saved. Retry.')),
          ),
        );
      }
    }
  }

  Future<void> time(bool start) async {
    final minutes = start ? settings!.start : settings!.end;
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    if (value != null && mounted) {
      await change(() {
        if (start) {
          settings!.start = value.hour * 60 + value.minute;
        } else {
          settings!.end = value.hour * 60 + value.minute;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = settings;
    Widget toggle(String zh, String en, bool value, ValueChanged<bool> set) =>
        SwitchListTile(
          dense: false,
          title: Text(tr(zh, en)),
          value: value,
          onChanged: (v) => change(() => set(v)),
        );
    String clock(int m) =>
        '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
    return ListTileTheme(
      data: ListTileTheme.of(context).copyWith(
        minVerticalPadding: 2,
        minTileHeight: 48,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleMedium!.copyWith(fontSize: 21),
        subtitleTextStyle: Theme.of(
          context,
        ).textTheme.bodyMedium!.copyWith(fontSize: 16),
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(tr('聊天通知', 'Chat notifications'))),
        body: s == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  toggle(
                    '聊天通知',
                    'Chat notifications',
                    s.enabled,
                    (v) => s.enabled = v,
                  ),
                  toggle('通知声音', 'Sound', s.sound, (v) => s.sound = v),
                  ListTile(
                    dense: false,
                    title: Text(tr('通知铃声', 'Ringtone')),
                    subtitle: Text(
                      s.ringtone == 'default'
                          ? tr('系统默认', 'System default')
                          : s.ringtone == 'silent'
                          ? tr('静音', 'Silent')
                          : tr('已选系统铃声', 'Selected system ringtone'),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: !Platform.isAndroid
                        ? null
                        : () async {
                            try {
                              final selected = await bridge
                                  .invokeMethod<String>('ringtone', s.ringtone);
                              if (selected != null && mounted) {
                                await change(() => s.ringtone = selected);
                              }
                            } catch (_) {
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr(
                                        '无法打开系统铃声选择器',
                                        'System ringtone picker unavailable',
                                      ),
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                  ),
                  ListTile(
                    dense: false,
                    title: Text(tr('恢复默认铃声', 'Restore default ringtone')),
                    onTap: () => change(() => s.ringtone = 'default'),
                  ),
                  toggle('震动', 'Vibration', s.vibrate, (v) => s.vibrate = v),
                  toggle(
                    '显示消息内容',
                    'Show message content',
                    s.preview,
                    (v) => s.preview = v,
                  ),
                  toggle(
                    '私聊通知',
                    'Direct messages',
                    s.direct,
                    (v) => s.direct = v,
                  ),
                  toggle('群聊通知', 'Group messages', s.group, (v) => s.group = v),
                  toggle('免打扰时间', 'Quiet hours', s.quiet, (v) => s.quiet = v),
                  if (s.quiet)
                    Row(
                      children: [
                        Expanded(
                          child: ListTile(
                            dense: false,
                            title: Text(tr('开始', 'Start')),
                            subtitle: Text(clock(s.start)),
                            onTap: () => time(true),
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            dense: false,
                            title: Text(tr('结束', 'End')),
                            subtitle: Text(clock(s.end)),
                            onTap: () => time(false),
                          ),
                        ),
                      ],
                    ),
                  if (Platform.isAndroid)
                    ListTile(
                      dense: false,
                      title: Text(tr('允许通知', 'Allow notifications')),
                      onTap: () async {
                        final plugin = await SolarReminderService.instance
                            .notifications();
                        final granted = await plugin
                            .resolvePlatformSpecificImplementation<
                              AndroidFlutterLocalNotificationsPlugin
                            >()
                            ?.requestNotificationsPermission();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                granted == true
                                    ? tr('通知权限已开启', 'Notifications allowed')
                                    : tr(
                                        '通知权限未开启，可点击下方“系统通知设置”开启',
                                        'Notifications are disabled. Open System notification settings below.',
                                      ),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  if (Platform.isAndroid)
                    ListTile(
                      dense: false,
                      title: Text(tr('系统通知设置', 'System notification settings')),
                      subtitle: Text(
                        tr(
                          '系统设置优先；可在系统中修改通知渠道的声音和震动',
                          'System channel settings take precedence.',
                        ),
                      ),
                      onTap: () => bridge.invokeMethod<void>('settings'),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      style: const TextStyle(fontSize: 16),
                      tr(
                        '关闭通知不影响消息同步。当前尚未接通后台推送，App 完全关闭后不能保证收到通知。',
                        'Disabling notifications does not stop sync. Push is not configured; delivery when the app is closed is not guaranteed.',
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
