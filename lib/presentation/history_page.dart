import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../domain/history_range.dart';
import '../domain/models.dart';
import 'session_history_page.dart';
import 'shared.dart';

class HistoryPage extends StatefulWidget {
  final AppController app;
  final CounterProject project;
  const HistoryPage({super.key, required this.app, required this.project});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  AppController get app => widget.app;
  HistoryPeriod period = HistoryPeriod.today;
  late HistoryRange range = HistoryRange.forPeriod(period, DateTime.now());
  List<Map<String, Object?>> rows = [];
  bool busy = false, more = true, failed = false;
  int request = 0;
  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  Future<void> load({bool reset = false}) async {
    final token = ++request;
    setState(() {
      busy = true;
      failed = false;
      if (reset) rows = [];
    });
    try {
      final result = await app.repository.changes(
        widget.project.id,
        from: range.from,
        until: range.until,
        offset: rows.length,
      );
      if (!mounted || token != request) return;
      setState(() {
        rows = [...rows, ...result];
        more = result.length == 100;
        busy = false;
      });
    } catch (_) {
      if (mounted && token == request) {
        setState(() {
          busy = false;
          failed = true;
        });
      }
    }
  }

  Future<void> select(HistoryPeriod value) async {
    if (value == HistoryPeriod.custom) {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200),
        initialDateRange: range.from == null
            ? null
            : DateTimeRange(
                start: range.from!,
                end: range.until!.subtract(const Duration(microseconds: 1)),
              ),
      );
      if (picked == null || !mounted) return;
      range = HistoryRange.custom(picked.start, picked.end);
    } else {
      range = HistoryRange.forPeriod(value, DateTime.now());
    }
    setState(() => period = value);
    await load(reset: true);
  }

  String label(HistoryPeriod value) => switch (value) {
    HistoryPeriod.today => app.text('今天', 'Today'),
    HistoryPeriod.yesterday => app.text('昨天', 'Yesterday'),
    HistoryPeriod.week => app.text('本周', 'This week'),
    HistoryPeriod.month => app.text('本月', 'This month'),
    HistoryPeriod.custom => app.text('自定义', 'Custom'),
    HistoryPeriod.all => app.text('全部', 'All'),
  };
  String source(Object? value) => switch (value) {
    'volumeUp' => app.text('音量上键', 'Volume up key'),
    'volumeDown' => app.text('音量下键', 'Volume down key'),
    'screen' => app.text('屏幕计数', 'Screen input'),
    'keyboard' => app.text('空格键', 'Space key'),
    'manual_add' => app.text('手动增加', 'Manual addition'),
    'manual_subtract' => app.text('手动减少', 'Manual subtraction'),
    'manual_set' => app.text('指定总数', 'Set total'),
    'legacy_correction' => app.text('旧版人工校正', 'Legacy correction'),
    _ => app.text('旧记录（来源未保存）', 'Legacy record (source unavailable)'),
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.project.name} · ${app.text('历史记录', 'History')}'),
      actions: [
        IconButton(
          tooltip: app.text('会话记录', 'Session history'),
          icon: const Icon(Icons.view_timeline_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) =>
                  SessionHistoryPage(app: app, project: widget.project),
            ),
          ),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in HistoryPeriod.values)
                    ChoiceChip(
                      label: Text(label(value)),
                      selected: period == value,
                      onSelected: busy ? null : (_) => select(value),
                    ),
                ],
              ),
            ),
            if (range.from != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${stamp(range.from).substring(0, 10)} — ${stamp(range.until!.subtract(const Duration(microseconds: 1))).substring(0, 10)}',
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => load(reset: true),
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length + 1,
                  itemBuilder: (context, index) {
                    if (index == rows.length) {
                      if (busy) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      if (failed) {
                        return TextButton(
                          onPressed: () => load(),
                          child: Text(
                            app.text('加载失败，重试', 'Loading failed. Retry'),
                          ),
                        );
                      }
                      if (rows.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text(
                              app.text(
                                '此日期范围暂无记录',
                                'No records in this date range',
                              ),
                            ),
                          ),
                        );
                      }
                      return more
                          ? TextButton(
                              onPressed: () => load(),
                              child: Text(app.text('加载更多', 'Load more')),
                            )
                          : const SizedBox(height: 24);
                    }
                    final row = rows[index];
                    final delta = row['delta'] as int;
                    final time = DateTime.parse(
                      row['occurredAt'] as String,
                    ).toLocal();
                    final fraction =
                        (time.millisecond * 1000 + time.microsecond)
                            .toString()
                            .padLeft(6, '0');
                    return Card(
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surface,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    source(row['source']),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  '${delta >= 0 ? '+' : ''}$delta',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('${stamp(time)}.$fraction'),
                            if (row['beforeValue'] != null)
                              Text(
                                '${app.text('修改前', 'Before')}: ${row['beforeValue']}',
                              ),
                            if (row['afterValue'] != null)
                              Text(
                                '${app.text('当时累计总数', 'Total after')}: ${row['afterValue']}',
                              ),
                            if ((row['note'] as String? ?? '').isNotEmpty)
                              Text('${app.text('备注', 'Note')}: ${row['note']}'),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
