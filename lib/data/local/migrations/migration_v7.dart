import 'package:sqflite/sqflite.dart';

Future<void> migrateToV7(Database db) async {
  await db.execute('ALTER TABLE notes ADD COLUMN source_post_id TEXT');
  await db.execute(
    "ALTER TABLE notes ADD COLUMN source_meta TEXT NOT NULL DEFAULT '{}'",
  );
  await db.execute(
    "CREATE TABLE practice_links(project_id TEXT PRIMARY KEY, practice_id TEXT NOT NULL, group_id TEXT NOT NULL, linked_at TEXT NOT NULL DEFAULT '')",
  );
  await db.execute(
    'CREATE TABLE practice_outbox(event_id TEXT PRIMARY KEY, practice_id TEXT NOT NULL, group_id TEXT NOT NULL, next_attempt INTEGER NOT NULL DEFAULT 0)',
  );
  await db.execute(
    '''CREATE TRIGGER practice_count_insert AFTER INSERT ON count_events
    WHEN (SELECT applying_remote FROM sync_scope WHERE singleton=1)=0
    BEGIN INSERT OR IGNORE INTO practice_outbox(event_id,practice_id,group_id)
    SELECT NEW.id,practice_id,group_id FROM practice_links WHERE project_id=NEW.projectId AND NEW.occurredAt>=linked_at; END''',
  );
}
