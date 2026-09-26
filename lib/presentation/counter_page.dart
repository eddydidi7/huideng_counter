import '../services/counter_haptics.dart';
import 'group_practice_page.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/app_controller.dart';
import '../domain/models.dart';
import 'shared.dart';
import 'settings_page.dart';
import 'history_page.dart';

class CounterPage extends StatefulWidget {
  final AppController app;
  final CounterProject project;
  const CounterPage({super.key, required this.app, required this.project});
  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> with WidgetsBindingObserver {
  static const channel = MethodChannel('org.huideng.counter/volume');
  String? session;
  int added = 0;
  bool hapticWarningShown = false;
  late BigInt total = widget.project.balance;
  late CounterRepository repository = app.repository;
  late CounterProject current = widget.project;
  bool accepting = true, leaving = false, adjusting = false, allowPop = false;
  Future<void> queue = Future.value();
  final focus = FocusNode();
  AppController get app => widget.app;
  bool get android => defaultTargetPlatform == TargetPlatform.android;
  @override
  void initState() {
    super.initState();
    // Keep already queued taps bound to the database that accepted them.
    repository = app.repository;
    app.addListener(onAppChanged);
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(key);
    if (android) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'increment') {
          final source = switch (call.arguments) {
            'volumeUp' => CountSource.volumeUp,
            'volumeDown' => CountSource.volumeDown,
            _ => null,
          };
          if (source != null) tap(source: source);
        }
      });
      unawaited(volume(true));
    }
  }

  void onAppChanged() {
    if (!mounted || !identical(repository, app.repository)) return;
    final matches = app.projects.where((p) => p.id == widget.project.id);
    if (matches.isEmpty) {
      accepting = false;
      unawaited(volume(false));
      return;
    }
    // Read after pending taps, so an older reload cannot replace a newer tap.
    queue = queue
        .then((_) async {
          final projects = await repository.projects();
          final found = projects.where((p) => p.id == widget.project.id);
          if (mounted && found.isNotEmpty) {
            setState(() {
              current = found.single;
              total = current.balance;
            });
          }
        })
        .catchError((Object error) {
          if (mounted) showFailure(context, app, error);
        });
  }

  bool key(KeyEvent event) {
    if (android ||
        event.logicalKey != LogicalKeyboardKey.space ||
        !accepting ||
        leaving) {
      return false;
    }
    if (event is KeyDownEvent) tap(source: CountSource.keyboard);
    return true;
  }

  void tap({CountSource source = CountSource.screen}) {
    if (!accepting || leaving || adjusting) return;
    if (total < BigInt.zero || total >= BigInt.from(maxCount)) {
      showFailure(context, app, RangeError('count'));
      return;
    }
    final occurredAt = DateTime.now();
    queue = queue
        .then((_) async {
          session ??= await repository.beginSession(
            widget.project.id,
            startedAt: occurredAt,
          );
          final newTotal = await repository.increment(
            session!,
            source: source,
            occurredAt: occurredAt,
          );
          if (mounted) {
            setState(() {
              total = BigInt.from(newTotal);
              added++;
            });
          }
          if (mounted && accepting && !leaving) {
            unawaited(countHaptic());
          }
        })
        .catchError((Object error) {
          if (mounted) showFailure(context, app, error);
        });
  }

  Future<void> countHaptic() async {
    if (!app.haptics) return;
    final sent = await CounterHaptics.pulse(enabled: true);
    if (!mounted || sent || !android || hapticWarningShown) return;
    hapticWarningShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          app.text(
            '计数已保存；震动不可用，请在手机设置中开启触感反馈',
            'Count saved. Enable touch vibration in phone settings for feedback.',
          ),
        ),
      ),
    );
  }

  Future<void> finish() async {
    await queue;
    if (session != null) {
      await repository.endSession(session!);
      session = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      accepting = false;
      unawaited(volume(false));
      queue = queue
          .then((_) async {
            if (session != null) {
              await repository.endSession(session!);
              session = null;
            }
          })
          .catchError((Object error) {
            if (mounted) showFailure(context, app, error);
          });
    } else if (state == AppLifecycleState.resumed && !leaving && !adjusting) {
      queue = queue.then((_) {
        if (mounted) {
          setState(() {
            added = 0;
            accepting = true;
          });
          unawaited(volume(true));
        }
      });
    }
  }

  Future<void> leave() async {
    if (leaving) return;
    setState(() {
      leaving = true;
      accepting = false;
    });
    try {
      await volume(false);
      await finish();
      await app.reload();
      if (mounted) {
        setState(() => allowPop = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          leaving = false;
          accepting = true;
        });
        unawaited(volume(true));
        showFailure(context, app, e);
      }
    }
  }

  Future<void> volume(bool enabled) async {
    if (!android) return;
    try {
      await channel.invokeMethod<void>('setEnabled', enabled);
    } catch (e) {
      if (mounted && enabled) showFailure(context, app, e);
    }
  }

  Future<void> openDetails({bool history = false}) async {
    if (leaving || adjusting) return;
    setState(() {
      adjusting = true;
      accepting = false;
    });
    try {
      await volume(false);
      await finish();
      await app.reload();
      final project = app.projects.firstWhere((p) => p.id == widget.project.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => history
              ? HistoryPage(app: app, project: project)
              : CorrectionPage(app: app, project: project),
        ),
      );
      await app.reload();
      if (mounted) {
        setState(() {
          total = app.projects
              .firstWhere((p) => p.id == widget.project.id)
              .balance;
          added = 0;
        });
      }
    } catch (e) {
      if (mounted) showFailure(context, app, e);
    } finally {
      if (mounted && !leaving) {
        final resumed =
            WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        setState(() {
          adjusting = false;
          accepting = resumed;
        });
        await volume(resumed);
      }
    }
  }

  @override
  void dispose() {
    app.removeListener(onAppChanged);
    accepting = false;
    unawaited(finish().catchError((Object _) {}));
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(key);
    focus.dispose();
    if (android) {
      channel.setMethodCallHandler(null);
      unawaited(volume(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) leave();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: leave,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(current.name),
        actions: [
          IconButton(
            tooltip: '相关共修群',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () =>
                choosePracticeGroup(context, app, projectId: widget.project.id),
          ),
          IconButton(
            tooltip: app.text('调整计数', 'Adjust count'),
            onPressed: leaving || adjusting ? null : () => openDetails(),
            icon: const Icon(Icons.tune, size: 30, color: Color(0xff64b5f6)),
          ),
          IconButton(
            tooltip: app.text('历史记录', 'History'),
            onPressed: leaving || adjusting
                ? null
                : () => openDetails(history: true),
            icon: const Icon(Icons.history, size: 30, color: Color(0xffb39ddb)),
          ),
        ],
      ),
      body: Focus(
        focusNode: focus,
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => tap(),
          child: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, imageArea) => ProjectImage(
                        key: const ValueKey('counter-image'),
                        path: current.imagePath,
                        size: imageArea.maxWidth,
                        height: imageArea.maxHeight,
                        fit: BoxFit.contain,
                        cornerRadius: 0,
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .35,
                    ),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(app.text('本次念诵', 'This session')),
                                      FittedBox(
                                        child: Text(
                                          '$added',
                                          style: const TextStyle(
                                            fontSize: 32,
                                            fontWeight: FontWeight.w300,
                                          ),
                                          semanticsLabel:
                                              '${app.text('本次', 'Session')} $added',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(app.text('累计计数', 'Total count')),
                                      FittedBox(
                                        child: Text(
                                          '$total',
                                          style: const TextStyle(fontSize: 26),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (total < BigInt.zero ||
                                total > BigInt.from(maxCount))
                              Text(
                                app.text(
                                  '累计超出有效范围，请在右上角校正后继续。记录已保留。',
                                  'Balance is outside the valid range. Adjust it at the top right to continue. Events are retained.',
                                ),
                              ),
                            Text(
                              android
                                  ? app.text(
                                      '轻触图片或空白区域／两个音量键均可计数 · 自动保存',
                                      'Tap image or open area, or use either volume key · Auto-saved',
                                    )
                                  : Platform.isWindows
                                  ? app.text(
                                      '点击图片或空白区域／空格键计数 · 自动保存',
                                      'Click image or open area, or press Space · Auto-saved',
                                    )
                                  : app.text(
                                      '轻触图片或空白区域计数 · 自动保存',
                                      'Tap image or open area to count · Auto-saved',
                                    ),
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            TextButton(
                              onPressed: leaving ? null : leave,
                              child: Text(app.text('结束本次念诵', 'Finish session')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
