import 'package:sqflite/sqflite.dart';

Future<void> migrateToV6(Database db) async {
  await db.execute('''CREATE TABLE note_cloud (
    note_id TEXT PRIMARY KEY REFERENCES notes(id), revision INTEGER NOT NULL DEFAULT 0, conflict_of TEXT
  )''');
  await db.execute('''CREATE TABLE note_outbox (
    note_id TEXT PRIMARY KEY REFERENCES notes(id), generation INTEGER NOT NULL DEFAULT 1,
    request_id TEXT, payload TEXT, attempts INTEGER NOT NULL DEFAULT 0,
    next_at INTEGER NOT NULL DEFAULT 0, last_error TEXT
  )''');
  await db.execute('''CREATE TABLE note_sync_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), cursor INTEGER NOT NULL DEFAULT 0,
    last_sync_at TEXT
  )''');
  await db.insert('note_sync_state', {'singleton': 1});
  const local = '(SELECT applying_remote FROM sync_scope WHERE singleton=1)=0';
  for (final verb in [
    'INSERT',
    'UPDATE OF title,body,isPinned,isFavorite,isArchived,deletedAt',
  ]) {
    final name = verb == 'INSERT' ? 'insert' : 'update';
    await db.execute('''CREATE TRIGGER note_queue_$name AFTER $verb ON notes
      WHEN $local BEGIN
      INSERT INTO note_outbox(note_id) VALUES(NEW.id)
      ON CONFLICT(note_id) DO UPDATE SET generation=generation+1;
      END''');
  }
  await db.execute('INSERT INTO note_outbox(note_id) SELECT id FROM notes');
}
