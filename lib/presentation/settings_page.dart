import '../services/counter_haptics.dart';
import 'windows_display.dart';
import 'app_update_page.dart';
import 'chat_notification_settings_page.dart';
import 'account_panel.dart';
import 'my_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/app_controller.dart';
import '../domain/models.dart';
import 'history_page.dart';
import 'shared.dart';

class SettingsPage extends StatefulWidget {
  final AppController app;
  const SettingsPage({super.key, required this.app});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final version = PackageInfo.fromPlatform();
  AppController get app => widget.app;
  Future<void> set(String key, String value) async {
    try {
      await app.set(key, value);
    } catch (e) {
      if (mounted) showFailure(context, app, e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (_, _) => Scaffold(
      appBar: AppBar(title: Text(app.text('设置', 'Settings'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: Text(app.text('聊天通知', 'Chat notifications')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ChatNotificationSettingsPage(app: app),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.system_update),
                title: Text(app.text('检查更新', 'Check for updates')),
                subtitle: FutureBuilder<PackageInfo>(
                  future: version,
                  builder: (_, snapshot) => Text(
                    snapshot.hasData
                        ? '当前版本：${snapshot.data!.version}'
                        : '当前版本：待读取',
                  ),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AppUpdatePage(app: app),
                  ),
                ),
              ),
              ExpansionTile(
                key: const ValueKey('settings-account'),
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(app.text('账号与同步', 'Account and sync')),
                children: [accountSyncContent(app)],
              ),
              ListTile(
                key: const ValueKey('settings-services'),
                leading: const Icon(Icons.apps_outlined),
                title: Text(app.text('常用', 'Common')),
                subtitle: Text(
                  app.text(
                    '供佛 · 共修 · 公共网盘 · 收藏',
                    'Offerings · Practice · Drive · Favorites',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsServicesPage(app: app),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(app.text('关于与联系', 'About and contact')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => AboutPage(app: app)),
                ),
              ),
              const Divider(),
              Text(
                app.text('偏好设置', 'Preferences'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (usesWindowsDisplay) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('windows-display-${app.windowsDisplaySize}'),
                  initialValue: app.windowsDisplaySize,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: app.text('显示大小', 'Display size'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'small',
                      child: Text(app.text('小', 'Small')),
                    ),
                    DropdownMenuItem(
                      value: 'standard',
                      child: Text(app.text('标准', 'Standard')),
                    ),
                    DropdownMenuItem(
                      value: 'large',
                      child: Text(app.text('大', 'Large')),
                    ),
                    DropdownMenuItem(
                      value: 'extraLarge',
                      child: Text(app.text('特大', 'Extra large')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) set('windowsDisplaySize', value);
                  },
                ),
                const SizedBox(height: 10),
              ],
              DropdownButtonFormField<String>(
                initialValue: app.languageMode,
                decoration: InputDecoration(
                  labelText: app.text('语言 / Language', 'Language / 语言'),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text(app.text('跟随系统', 'Follow system')),
                  ),
                  const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                  const DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (v) {
                  if (v != null) set('language', v);
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('colors-${app.colorPreference}'),
                initialValue: app.colorPreference,
                decoration: InputDecoration(
                  labelText: app.text('颜色偏好', 'Color preference'),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text(app.text('跟随系统', 'Follow system')),
                  ),
                  DropdownMenuItem(
                    value: 'dark',
                    child: Text(app.text('黑色', 'Black')),
                  ),
                  DropdownMenuItem(
                    value: 'light',
                    child: Text(app.text('白色', 'White')),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) set('colorPreference', value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(app.text('计数震动反馈', 'Haptic feedback')),
                subtitle: Text(
                  app.text('在支持震动的设备上生效', 'On devices with haptic support'),
                ),
                value: app.haptics,
                onChanged: (v) async {
                  await set('haptics', '$v');
                  if (!mounted || !v || !app.haptics) return;
                  final supported = await CounterHaptics.pulse(enabled: true);
                  if (!context.mounted || supported) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        app.text(
                          '当前设备无法启动震动，请检查系统震动设置',
                          'Vibration unavailable. Check system vibration settings.',
                        ),
                      ),
                    ),
                  );
                },
              ),
              const Divider(height: 32),
              Text(
                app.text('累计总数校正', 'Correct totals'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                app.text(
                  '校正不会改变今日念诵数量，每次修改都会保存记录。',
                  'Corrections are logged and do not change today’s recitations.',
                ),
              ),
              if (app.projects.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(app.text('请先创建计数项目', 'Create a counter first')),
                ),
              for (final p in app.projects)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ProjectImage(path: p.imagePath, size: 44),
                  title: Text(p.name),
                  subtitle: Text(
                    '${app.text('累计', 'Total')}: ${p.displayTotal}',
                  ),
                  trailing: const Icon(Icons.tune),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CorrectionPage(app: app, project: p),
                    ),
                  ),
                ),
              Text(app.text('文殊计数器 · 第一阶段', 'Manjushri Counter · Phase 1')),
              const SizedBox(height: 8),
              Text(
                app.text(
                  '计数先保存在本机；登录后同步到当前账号。',
                  'Counts are saved locally first and sync to your account after sign-in.',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class CorrectionPage extends StatefulWidget {
  final AppController app;
  final CounterProject project;
  const CorrectionPage({super.key, required this.app, required this.project});
  @override
  State<CorrectionPage> createState() => _CorrectionPageState();
}

class _CorrectionPageState extends State<CorrectionPage> {
  CorrectionMode mode = CorrectionMode.add;
  final amount = TextEditingController();
  final note = TextEditingController();
  final form = GlobalKey<FormState>();
  bool saving = false;
  AppController get app => widget.app;
  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  int? get after {
    final n = int.tryParse(amount.text);
    if (n == null) return null;
    return switch (mode) {
      CorrectionMode.add => widget.project.total + n,
      CorrectionMode.subtract => widget.project.total - n,
      CorrectionMode.set => n,
    };
  }

  Future<void> save() async {
    if (!form.currentState!.validate() || saving) return;
    setState(() => saving = true);
    try {
      await app.repository.correct(
        widget.project.id,
        mode,
        int.parse(amount.text),
        note.text,
      );
      await app.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        showFailure(context, app, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        app.text(
          '校正 · ${widget.project.name}',
          'Correct · ${widget.project.name}',
        ),
      ),
      actions: [
        IconButton(
          tooltip: app.text('历史记录', 'History'),
          icon: const Icon(Icons.history),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => HistoryPage(app: app, project: widget.project),
            ),
          ),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                '${app.text('当前累计总数', 'Current total')}: ${widget.project.displayTotal}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving
                          ? null
                          : () => setState(() {
                              mode = CorrectionMode.add;
                              amount.text = '1';
                            }),
                      child: const Text('+1'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving
                          ? null
                          : () => setState(() {
                              mode = CorrectionMode.subtract;
                              amount.text = '1';
                            }),
                      child: const Text('-1'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<CorrectionMode>(
                key: ValueKey(mode),
                initialValue: mode,
                decoration: InputDecoration(
                  labelText: app.text('校正方式', 'Correction type'),
                ),
                items: [
                  DropdownMenuItem(
                    value: CorrectionMode.add,
                    child: Text(app.text('增加数量', 'Add count')),
                  ),
                  DropdownMenuItem(
                    value: CorrectionMode.subtract,
                    child: Text(app.text('减少数量', 'Subtract count')),
                  ),
                  DropdownMenuItem(
                    value: CorrectionMode.set,
                    child: Text(app.text('直接设置累计总数', 'Set total')),
                  ),
                ],
                onChanged: saving ? null : (v) => setState(() => mode = v!),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: amount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: app.text('数量', 'Count')),
                validator: (v) =>
                    after == null ||
                        after! < 0 ||
                        after! > maxCount ||
                        (int.tryParse(v ?? '') ?? -1) > maxCount
                    ? app.text(
                        '请输入有效数量，结果不能小于零或超出上限',
                        'Enter a valid count; total must remain within range',
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: note,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: app.text('备注（可选）', 'Note (optional)'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${app.text('修改后', 'After')}: ${after ?? '—'}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(app.text('保存校正并记录', 'Save correction and log')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
