import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:timezone/timezone.dart' as tz;
import '../core/app_controller.dart';
import '../domain/solar_times.dart';
import '../services/solar_location_service.dart';
import '../services/solar_time_service.dart';
import '../services/solar_reminder_service.dart';

class SolarPage extends StatefulWidget {
  const SolarPage({super.key, required this.app, this.locationService});
  final AppController app;
  final SolarLocationService? locationService;
  @override
  State<SolarPage> createState() => _SolarPageState();
}

class _SolarPageState extends State<SolarPage> with WidgetsBindingObserver {
  late final locations = widget.locationService ?? SolarLocationService();
  SolarLocation? location;
  SolarTimes? times;
  DateTime date = DateTime.now();
  bool loading = true,
      locating = false,
      reminderBusy = false,
      thirty = false,
      three = false;
  bool followToday = true;
  String? failure, reminderError;
  Timer? timer, nameRetry;
  int locationGeneration = 0;
  bool resolvingName = false;
  String tr(String zh, String en) => widget.app.text(zh, en);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
    timer = Timer.periodic(const Duration(minutes: 1), (_) => updateToday());
  }

  @override
  void dispose() {
    timer?.cancel();
    nameRetry?.cancel();
    locationGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      updateToday();
    }
  }

  void updateToday() {
    if (!mounted || location == null) return;
    if (followToday) date = location!.today();
    calculate();
  }

  void calculate() {
    if (!mounted || location == null) return;
    try {
      final result = const SolarTimeService().at(date, location!);
      setState(() => times = result);
    } catch (e) {
      debugPrint('Solar calculation failed: ${e.runtimeType}');
      setState(() {
        times = null;
        failure = 'calculation';
      });
    }
  }

  Future<void> load() async {
    try {
      final cached = await locations.load();
      if (!mounted) return;
      setState(() {
        location = cached;
        loading = false;
      });
      if (cached != null) {
        date = cached.today();
        calculate();
      }
      // Do not await GPS before painting cached results.
      if (cached?.manual != true) unawaited(refresh());
      final a = await SolarReminderService.instance.enabled(30);
      final b = await SolarReminderService.instance.enabled(3);
      if (mounted) {
        setState(() {
          thirty = a;
          three = b;
        });
      }
    } catch (e) {
      debugPrint('Solar initialization failed: ${e.runtimeType}');
      if (mounted) {
        setState(() {
          loading = false;
          failure = 'cache';
        });
      }
    }
  }

  Future<void> refresh({bool explicit = false}) async {
    if (locating) return;
    nameRetry?.cancel();
    final generation = ++locationGeneration;
    setState(() {
      locating = true;
      failure = null;
    });
    try {
      final value = await locations.refresh(
        previous: location,
        explicit: explicit,
      );
      if (!mounted || generation != locationGeneration) return;
      setState(() => location = value);
      if (followToday) date = value.today();
      calculate();
      unawaited(resolvePlace(value, generation));
      await updateReminders();
    } catch (e) {
      debugPrint('Solar location failed: ${e.runtimeType}');
      if (mounted) {
        setState(
          () => failure = e is SolarLocationFailure ? e.code : 'unavailable',
        );
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> resolvePlace(
    SolarLocation fix,
    int generation, [
    int attempt = 0,
  ]) async {
    if (!mounted || generation != locationGeneration || fix.manual) return;
    setState(() => resolvingName = true);
    String name;
    try {
      name = await locations.resolveName(fix);
    } catch (e) {
      debugPrint('Solar place lookup: ${e.runtimeType}');
      name = fix.name;
    }
    if (!mounted ||
        generation != locationGeneration ||
        location?.manual == true) {
      return;
    }
    setState(() => resolvingName = false);
    if (name.isNotEmpty) {
      final named = SolarLocation(
        latitude: fix.latitude,
        longitude: fix.longitude,
        name: name,
        updatedAt: fix.updatedAt,
        savedOffsetMinutes: fix.savedOffsetMinutes,
        timezoneId: fix.timezoneId,
      );
      setState(() => location = named);
      try {
        await locations.save(named);
      } catch (e) {
        debugPrint('Solar named cache save: ${e.runtimeType}');
      }
    } else if (attempt < 2) {
      nameRetry = Timer(
        Duration(seconds: 10 * (attempt + 1)),
        () => unawaited(resolvePlace(fix, generation, attempt + 1)),
      );
    }
  }

  Future<void> updateReminders() async {
    try {
      await SolarReminderService.instance.refresh();
    } catch (e) {
      debugPrint('Solar reminder refresh failed: ${e.runtimeType}');
      if (mounted) {
        setState(
          () => reminderError = tr(
            '提醒未能更新，请检查通知和闹钟权限后重新开启。',
            'Reminders could not update. Check notification and alarm permissions.',
          ),
        );
      }
    }
  }

  Future<void> toggle(int minutes, bool value) async {
    setState(() {
      reminderBusy = true;
      reminderError = null;
    });
    try {
      await SolarReminderService.instance.setEnabled(
        minutes,
        value,
        english: widget.app.english,
      );
      if (mounted) {
        setState(() {
          if (minutes == 30) {
            thirty = value;
          } else {
            three = value;
          }
        });
      }
    } catch (e) {
      debugPrint('Solar reminder setting failed: ${e.runtimeType}');
      if (mounted) {
        setState(
          () => reminderError = tr(
            '提醒设置失败，请允许通知和“闹钟与提醒”权限后重试。',
            'Could not set reminder. Allow notifications and alarms, then retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => reminderBusy = false);
    }
  }

  String errorText() {
    final reason = switch (failure) {
      'disabled' => tr('定位服务未开启', 'Location services are off'),
      'denied' => tr('尚未允许定位权限', 'Location permission not granted'),
      'permanent' => tr(
        '定位权限已关闭，请在系统设置中开启',
        'Enable location permission in system settings',
      ),
      'save' => tr('位置未能保存，请重试', 'Could not save location. Retry'),
      'cache' => tr('无法读取保存的位置', 'Could not load saved location'),
      'calculation' => tr('暂时无法计算，请检查地点和日期', 'Check the location and date'),
      _ => tr('无法获取当前位置', 'Unable to get current location'),
    };
    return location == null
        ? reason
        : '$reason。${tr('正在使用上次位置计算', 'Using saved location')}';
  }

  Future<void> chooseDate() async {
    final result = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (result == null || !mounted) return;
    followToday = false;
    date = result;
    calculate();
  }

  Future<void> manual() async {
    final lat = TextEditingController(
      text: location?.latitude.toString() ?? '',
    );
    final lon = TextEditingController(
      text: location?.longitude.toString() ?? '',
    );
    final name = TextEditingController(text: location?.name ?? '');
    final zone = TextEditingController(text: location?.timezoneId ?? '');
    String? validation;
    final result = await showDialog<SolarLocation>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(tr('手动设置地点', 'Set location')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                      label: Text(tr('上海', 'Shanghai')),
                      onPressed: () {
                        lat.text = '31.2304';
                        lon.text = '121.4737';
                        name.text = tr('上海', 'Shanghai');
                        zone.text = 'Asia/Shanghai';
                      },
                    ),
                    ActionChip(
                      label: Text(tr('奥克兰', 'Auckland')),
                      onPressed: () {
                        lat.text = '-36.8485';
                        lon.text = '174.7633';
                        name.text = tr('奥克兰', 'Auckland');
                        zone.text = 'Pacific/Auckland';
                      },
                    ),
                  ],
                ),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: tr('地点名称（可选）', 'Location name (optional)'),
                  ),
                ),
                TextField(
                  controller: lat,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('纬度（-90～90）', 'Latitude (-90 to 90)'),
                  ),
                ),
                TextField(
                  controller: lon,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('经度（-180～180）', 'Longitude (-180 to 180)'),
                  ),
                ),
                TextField(
                  controller: zone,
                  decoration: InputDecoration(
                    labelText: tr('地点时区', 'Location timezone'),
                    hintText: 'Asia/Shanghai / Pacific/Auckland',
                  ),
                ),
                Text(
                  tr(
                    '异地查询必须填写当地时区，例如 Asia/Kolkata、Asia/Bangkok。',
                    'For remote locations use their timezone, e.g. Asia/Kolkata or Asia/Bangkok.',
                  ),
                ),
                if (validation != null)
                  Text(
                    validation!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final a = double.parse(lat.text.trim()),
                      b = double.parse(lon.text.trim());
                  if (!a.isFinite ||
                      a.abs() > 90 ||
                      !b.isFinite ||
                      b.abs() > 180) {
                    throw const FormatException();
                  }
                  SolarLocation.prepareZones();
                  final z = tz.getLocation(zone.text.trim());
                  Navigator.pop(
                    ctx,
                    SolarLocation(
                      latitude: a,
                      longitude: b,
                      name: name.text.trim(),
                      updatedAt: DateTime.now(),
                      savedOffsetMinutes: tz.TZDateTime.now(
                        z,
                      ).timeZoneOffset.inMinutes,
                      timezoneId: z.name,
                      manual: true,
                    ),
                  );
                } catch (_) {
                  update(
                    () => validation = tr(
                      '请检查经纬度和时区名称。',
                      'Check coordinates and timezone name.',
                    ),
                  );
                }
              },
              child: Text(tr('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    // Dialog route finishes its closing animation before controllers are disposed.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    lat.dispose();
    lon.dispose();
    name.dispose();
    zone.dispose();
    if (result == null || !mounted) return;
    locationGeneration++;
    nameRetry?.cancel();
    try {
      await locations.save(result);
      if (!mounted) return;
      setState(() {
        location = result;
        failure = null;
      });
      if (followToday) date = result.today();
      calculate();
      await updateReminders();
    } catch (e) {
      if (mounted) setState(() => failure = 'save');
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = times;
    final offset = value?.utcOffset.inMinutes ?? 0;
    final zoneLabel =
        'UTC${offset < 0 ? '-' : '+'}${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:${(offset.abs() % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('八关斋戒 · 日出日中', 'Eight precepts · Solar times')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (loading) const LinearProgressIndicator(),
            if (location != null) ...[
              Text(
                location!.name.isEmpty
                    ? tr(
                        resolvingName ? '已定位，正在查询地点名称…' : '已定位，地点名称暂不可用；可点重新定位',
                        'Location found; place name unavailable',
                      )
                    : location!.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Row(
                children: [
                  Text(tr('当前地点', 'Current location')),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: tr('地点名称查询说明', 'Place name lookup'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        content: Text(
                          tr(
                            '优先使用系统地点服务；失败时向 BigDataCloud 发送当前位置查询地名。查询失败不影响日出、日中计算。',
                            'Uses the system geocoder first, then sends the current position to BigDataCloud. Lookup failure does not affect solar calculations.',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: Text(tr('关闭', 'Close')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                '${tr('位置更新', 'Location updated')}: ${location!.updatedAt.toLocal().toString().substring(0, 16)}',
              ),
              Text(
                location!.timezoneId ??
                    tr(
                      '使用设备时区，请确保与所在地一致',
                      'Using device timezone; ensure it matches your location',
                    ),
              ),
            ],
            if (locating)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(tr('正在获取当前位置…', 'Getting current location…')),
              ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  errorText(),
                  key: const ValueKey('solar-location-error'),
                ),
              ),
            if (failure == 'disabled' ||
                failure == 'permanent' ||
                failure == 'denied')
              TextButton(
                onPressed: () async {
                  if (failure == 'disabled') {
                    await Geolocator.openLocationSettings();
                  } else {
                    await Geolocator.openAppSettings();
                  }
                },
                child: Text(tr('打开系统设置', 'Open system settings')),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  tooltip: tr('前一天', 'Previous day'),
                  onPressed: location == null
                      ? null
                      : () {
                          followToday = false;
                          date = DateTime(date.year, date.month, date.day - 1);
                          calculate();
                        },
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  tooltip: tr('后一天', 'Next day'),
                  onPressed: location == null
                      ? null
                      : () {
                          followToday = false;
                          date = DateTime(date.year, date.month, date.day + 1);
                          calculate();
                        },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            if (value != null) ...[
              Text(zoneLabel, textAlign: TextAlign.center),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('民用晨光始', 'Civil dawn')),
                trailing: Text(
                  value.civilDawn == null
                      ? tr('当日无晨光始', 'No civil dawn')
                      : value.clock(value.civilDawn),
                  style: const TextStyle(fontSize: 24),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('日出', 'Sunrise')),
                trailing: Text(
                  value.sunrise == null
                      ? tr('当日无日出', 'No sunrise')
                      : value.clock(value.sunrise),
                  style: const TextStyle(fontSize: 24),
                ),
              ),
              const Divider(),
              Text(
                tr('日中 · 太阳正午', 'Solar noon'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                value.clock(value.solarNoon),
                key: const ValueKey('solar-noon'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: locating ? null : () => refresh(explicit: true),
                  child: Text(tr('重新定位', 'Locate again')),
                ),
                OutlinedButton(
                  onPressed: location == null ? null : chooseDate,
                  child: Text(tr('选择日期', 'Choose date')),
                ),
                TextButton(
                  onPressed: location == null
                      ? null
                      : () {
                          followToday = true;
                          updateToday();
                        },
                  child: Text(tr('今天', 'Today')),
                ),
                TextButton(
                  onPressed: locating ? null : manual,
                  child: Text(tr('手动设置地点', 'Set location')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              tr(
                '非时食提醒：请在当地日中前完成进食。',
                'Meal reminder: finish eating before local solar noon.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('日中前30分钟提醒', '30 minutes before solar noon')),
              value: thirty,
              onChanged: location == null || reminderBusy
                  ? null
                  : (v) => toggle(30, v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('日中前3分钟提醒', '3 minutes before solar noon')),
              value: three,
              onChanged: location == null || reminderBusy
                  ? null
                  : (v) => toggle(3, v),
            ),
            if (reminderError != null)
              Text(
                reminderError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Text(
              tr(
                '提醒按今天起未来30天安排，打开应用时更新。更换地点后请重新定位；系统省电或关闭通知可能影响提醒。',
                'Reminders cover the next 30 days and refresh when the app opens. Refresh your location after travelling. Power saving or disabled notifications can affect delivery.',
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr(
                '日中时间仅作为当地太阳正午参考；具体持戒标准请依所受戒法及传承师长教导。',
                'Solar noon is a local astronomical reference. Follow the precepts and guidance of your lineage teacher.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                '按经纬度本地计算，无需日出网站。地形、海拔和大气会影响实际可见日出。',
                'Calculated locally from coordinates. Terrain, altitude and atmosphere affect observed sunrise.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
