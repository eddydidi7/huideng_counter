import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../domain/models.dart';
import 'shared.dart';

class SessionHistoryPage extends StatefulWidget {
  final AppController app;
  final CounterProject project;
  const SessionHistoryPage({
    super.key,
    required this.app,
    required this.project,
  });
  @override
  State<SessionHistoryPage> createState() => _SessionHistoryPageState();
}

class _SessionHistoryPageState extends State<SessionHistoryPage> {
  late Future<List<Map<String, Object?>>> records = widget.app.repository
      .history(widget.project.id);
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.project.name} · ${app.text('历史记录', 'History')}'),
      ),
      body: FutureBuilder(
        future: records,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton(
                onPressed: () => setState(
                  () => records = app.repository.history(widget.project.id),
                ),
                child: Text(app.text('加载失败，重试', 'Loading failed. Retry')),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) {
            return Center(
              child: Text(
                app.text('暂无念诵或校正记录', 'No sessions or corrections yet'),
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                itemBuilder: (_, index) {
                  final row = rows[index];
                  final correction = row['kind'] == 'correction';
                  final delta = row['delta'] as int;
                  return Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                correction ? Icons.tune : Icons.spa_outlined,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  correction
                                      ? app.text('人工校正', 'Manual correction')
                                      : app.text('念诵记录', 'Recitation session'),
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
                          const SizedBox(height: 12),
                          Text(
                            '${app.text('开始 / 时间', 'Start / time')}: ${stamp(row['occurredAt'])}',
                          ),
                          if (!correction)
                            Text(
                              '${app.text('结束', 'End')}: ${stamp(row['endAt'])}',
                            ),
                          if (correction)
                            Text(
                              '${app.text('修改前', 'Before')}: ${row['beforeValue']}',
                            ),
                          Text(
                            '${app.text('当时累计总数', 'Total after')}: ${row['afterValue']}',
                          ),
                          if (row['note'] != null &&
                              (row['note'] as String).isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('${app.text('备注', 'Note')}: ${row['note']}'),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
