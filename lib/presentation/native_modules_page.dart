import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native entry points. Never substitutes Gregorian dates for Tibetan dates or
/// an arbitrary clock time for solar noon before a verified source is connected.
class NativeModulePage extends StatelessWidget {
  final AppController app;
  final bool calendar;
  const NativeModulePage({
    super.key,
    required this.app,
    required this.calendar,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        calendar
            ? app.text('藏历', 'Tibetan calendar')
            : app.text(
                '八关斋戒 · 日出日中',
                'Eight precepts · Sunrise and solar noon',
              ),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              calendar
                  ? Icons.calendar_month_outlined
                  : Icons.wb_sunny_outlined,
              size: 56,
            ),
            const SizedBox(height: 24),
            Text(
              calendar
                  ? app.text(
                      '离线藏历数据准备中',
                      'Offline Tibetan calendar data is being prepared',
                    )
                  : app.text(
                      '尚未配置日出服务',
                      'Solar time service is not configured',
                    ),
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              calendar
                  ? app.text(
                      '将提供宁玛传承适用的藏历、公历对照及殊胜日。目前日期数据尚未核验，暂不显示藏历日期。',
                      'Tibetan and Gregorian dates with observances are planned. Verified calendar data is not available yet.',
                    )
                  : app.text(
                      '尚未配置和风天气服务，暂不能查询民用晨光始、日出和太阳正午。提醒默认关闭。',
                      'QWeather is not configured. Civil dawn, sunrise and solar noon are unavailable. Reminders are off.',
                    ),
            ),
            if (!calendar) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.settings_outlined),
                label: Text(app.text('日出服务设置', 'Solar service settings')),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: Text(app.text('日出服务设置', 'Solar service settings')),
                    content: Text(
                      app.text(
                        '和风天气服务尚未开通。需要先开通开发者账号及包含民用晨光始、日出、太阳正午的服务，再由管理员安全配置。当前不显示估算时间，也未启用提醒。',
                        'QWeather is not activated. A developer account and a service providing civil dawn, sunrise and solar noon are required, followed by secure administrator configuration. Estimates and reminders are currently disabled.',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(app.text('关闭', 'Close')),
                      ),
                      TextButton(
                        onPressed: () async {
                          final opened = await launchUrl(
                            Uri.parse('https://dev.qweather.com/'),
                            mode: LaunchMode.externalApplication,
                          );
                          if (!opened && dialogContext.mounted) {
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  app.text(
                                    '无法打开和风天气开发者网站',
                                    'Could not open QWeather developer website',
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                        child: Text(
                          app.text('和风天气开发者网站', 'QWeather developer website'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                app.text(
                  '非时食提醒：请在当地日中前完成进食。',
                  'Meal reminder: finish eating before local solar noon.',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                app.text(
                  '日中时间仅作为当地太阳正午参考；具体持戒标准请依所受戒法及传承师长教导。',
                  'Solar noon is a local astronomical reference. Follow the precepts and guidance of your lineage teacher.',
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
