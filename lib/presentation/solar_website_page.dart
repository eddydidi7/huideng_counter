import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';

/// Uses the platform's in-app browser, with an external browser fallback.
Future<bool> launchSolarWebsite(
  Uri solarWebsiteUrl, {
  bool external = false,
}) async {
  if (!external) {
    try {
      if (await launchUrl(solarWebsiteUrl, mode: LaunchMode.inAppBrowserView)) {
        return true;
      }
    } catch (error) {
      debugPrint('Solar in-app browser unavailable: ${error.runtimeType}');
    }
  }
  try {
    return await launchUrl(
      solarWebsiteUrl,
      mode: LaunchMode.externalApplication,
    );
  } catch (error) {
    debugPrint('Solar browser launch failed: ${error.runtimeType}');
    return false;
  }
}

class SolarWebsitePage extends StatefulWidget {
  final AppController app;
  const SolarWebsitePage({super.key, required this.app});

  @override
  State<SolarWebsitePage> createState() => SolarWebsitePageState();
}

class SolarWebsitePageState extends State<SolarWebsitePage> {
  bool _opening = false;
  bool _failed = false;

  Future<void> open({bool external = false}) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _failed = false;
    });
    final opened = await launchSolarWebsite(
      Uri.parse(widget.app.sunriseUrl),
      external: external,
    );
    if (!mounted) return;
    setState(() {
      _opening = false;
      _failed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: Text(app.text('日出与日中', 'Sunrise and solar noon'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.wb_sunny_outlined, size: 48),
              const SizedBox(height: 20),
              Text(
                app.text('中文日出与日中查询', 'Chinese sunrise and solar noon lookup'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                app.text(
                  '在查询网页选择所在地区，查看日出和太阳正午（日中）。网页地址由后台统一设置。',
                  'Choose your region on the website to view sunrise and solar noon. The website is configured by the administrator.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                app.text(
                  '请核对查询地区、日期及时间单位。日中是当地太阳正午，不一定是钟表上的 12:00。',
                  'Check the selected location, date and time units. Local solar noon is not necessarily 12:00 on the clock.',
                ),
              ),
              const SizedBox(height: 20),
              if (_failed) ...[
                Text(
                  app.text(
                    '无法打开网页，请检查浏览器后重试，或复制下方网址。',
                    'Could not open the website. Check your browser and retry, or copy the URL below.',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: _opening ? null : () => open(),
                icon: const Icon(Icons.open_in_browser),
                label: Text(
                  app.text(
                    _opening ? '正在打开…' : '查询日出与日中',
                    _opening ? 'Opening…' : 'Check sunrise and solar noon',
                  ),
                ),
              ),
              TextButton(
                onPressed: _opening ? null : () => open(external: true),
                child: Text(app.text('用系统浏览器打开', 'Open in system browser')),
              ),
              SelectableText(app.sunriseUrl),
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
              const SizedBox(height: 12),
              Text(
                app.text(
                  '当前使用第三方查询网页，需要联网；尚未启用自动提醒。',
                  'This third-party website requires internet access. Automatic reminders are not enabled.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
