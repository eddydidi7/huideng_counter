import 'package:sqflite/sqflite.dart';

/// Executed inside SQLite's version-upgrade transaction. Never deletes v1 data.
Future<void> migrateToV2(Database db) async {
  await db.execute('''CREATE TABLE count_changes (
    id TEXT PRIMARY KEY,
    projectId TEXT NOT NULL REFERENCES projects(id),
    sessionId TEXT,
    occurredAt TEXT NOT NULL,
    occurredAtMicros INTEGER NOT NULL,
    delta INTEGER NOT NULL,
    source TEXT NOT NULL,
    beforeValue INTEGER,
    afterValue INTEGER,
    note TEXT,
    originKind TEXT NOT NULL,
    originId TEXT NOT NULL,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    syncStatus TEXT NOT NULL DEFAULT 'pending',
    deletedAt TEXT,
    UNIQUE(originKind, originId)
  )''');
  await db.execute(
    'CREATE INDEX changes_project_time ON count_changes(projectId, occurredAtMicros, id)',
  );
  for (final table in ['count_events', 'corrections']) {
    var offset = 0;
    while (true) {
      final rows = await db.query(
        table,
        orderBy: 'id',
        limit: 500,
        offset: offset,
      );
      if (rows.isEmpty) break;
      final batch = db.batch();
      for (final row in rows) {
        final event = table == 'count_events';
        batch.insert('count_changes', {
          'id': row['id'],
          'projectId': row['projectId'],
          'sessionId': event ? row['sessionId'] : null,
          'occurredAt': row['occurredAt'],
          'occurredAtMicros': DateTime.parse(
            row['occurredAt'] as String,
          ).microsecondsSinceEpoch,
          'delta': event ? 1 : row['delta'],
          'source': event ? 'legacy_unknown' : 'legacy_correction',
          'beforeValue': event ? null : row['beforeValue'],
          'afterValue': event ? null : row['afterValue'],
          'note': event ? null : row['note'],
          'originKind': table,
          'originId': row['id'],
          'createdAt': row['createdAt'],
          'updatedAt': row['updatedAt'],
          'syncStatus': row['syncStatus'],
          'deletedAt': row['deletedAt'],
        });
      }
      await batch.commit(noResult: true);
      offset += rows.length;
    }
  }
  // Include tombstones in this historical reconciliation: soft deletion never
  // changed a project's stored total in v1.
  final mismatches = await db.rawQuery('''SELECT p.id FROM projects p
    LEFT JOIN (SELECT projectId, SUM(delta) AS total FROM count_changes GROUP BY projectId) c
    ON p.id = c.projectId WHERE p.total != COALESCE(c.total, 0) LIMIT 1''');
  if (mismatches.isNotEmpty) {
    throw StateError(
      'Migration reconciliation failed for ${mismatches.first['id']}. Original data retained.',
    );
  }
}
