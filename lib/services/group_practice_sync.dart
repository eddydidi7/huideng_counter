import '../core/app_controller.dart';
import '../data/repositories/sqlite_counter_repository.dart';

/// Account-bound durable outbox. Batches and UUID receipts prevent duplicate contributions.
class GroupPracticeSync {
  static bool _busy = false;
  static Future<void> flush(AppController app) async {
    if (_busy || app.repository is! SqliteCounterRepository) return;
    final client = app.cloud?.client,
        repo = app.repository as SqliteCounterRepository;
    final uid = client?.auth.currentUser?.id;
    if (client == null || uid == null || app.scopeId != uid) return;
    _busy = true;
    try {
      final rows = await repo.db.query(
        'practice_outbox',
        where: 'next_attempt<=?',
        whereArgs: [DateTime.now().millisecondsSinceEpoch],
        limit: 500,
      );
      final groups = <String, List<Map<String, Object?>>>{};
      for (final r in rows) {
        groups
            .putIfAbsent('${r['group_id']}/${r['practice_id']}', () => [])
            .add(r);
      }
      for (final batch in groups.values) {
        if (client.auth.currentUser?.id != uid ||
            !identical(repo, app.repository)) {
          break;
        }
        final ids = batch.map((r) => r['event_id']).toList(),
            where = List.filled(batch.length, '?').join(',');
        try {
          await client
              .rpc(
                'group_learning_v1',
                params: {
                  'p_action': 'count_many',
                  'p_data': {
                    'group_id': batch.first['group_id'],
                    'id': batch.first['practice_id'],
                    'event_ids': ids,
                  },
                },
              )
              .timeout(const Duration(seconds: 15));
          if (client.auth.currentUser?.id != uid ||
              !identical(repo, app.repository)) {
            break;
          }
          await repo.db.delete(
            'practice_outbox',
            where: 'event_id IN ($where)',
            whereArgs: ids,
          );
        } catch (_) {
          if (identical(repo, app.repository)) {
            await repo.db.update(
              'practice_outbox',
              {
                'next_attempt': DateTime.now()
                    .add(const Duration(minutes: 1))
                    .millisecondsSinceEpoch,
              },
              where: 'event_id IN ($where)',
              whereArgs: ids,
            );
          }
        }
      }
    } catch (_) {
      /* Keep pending events on disk for the next foreground retry. */
    } finally {
      _busy = false;
    }
  }
}
