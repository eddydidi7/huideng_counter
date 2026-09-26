import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Additive migration: no legacy row, UUID, total, path or timestamp is rewritten.
Future<void> migrateToV3(Database db) async {
  await db.execute('''CREATE TABLE sync_scope (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    user_id TEXT, device_id TEXT NOT NULL,
    applying_remote INTEGER NOT NULL DEFAULT 0 CHECK(applying_remote IN (0,1))
  )''');
  await db.insert('sync_scope', {
    'singleton': 1,
    'device_id': const Uuid().v4(),
  });
  await db.execute('''CREATE TABLE event_sync (
    event_id TEXT PRIMARY KEY REFERENCES count_changes(id),
    user_id TEXT, device_id TEXT NOT NULL,
    sync_status TEXT NOT NULL DEFAULT 'pending', server_revision INTEGER
  )''');
  await db.execute('''INSERT INTO event_sync(event_id, device_id)
    SELECT id, (SELECT device_id FROM sync_scope WHERE singleton = 1)
    FROM count_changes''');
  await db.execute('''CREATE TABLE sync_queue (
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','conflict')),
    last_error TEXT, request_id TEXT, payload TEXT,
    PRIMARY KEY(entity_type, entity_id)
  )''');
  await db.execute('''CREATE INDEX sync_queue_due
    ON sync_queue(state, next_attempt_at)''');
  await db.execute('''CREATE TABLE sync_state (
    user_id TEXT PRIMARY KEY, pull_cursor INTEGER NOT NULL DEFAULT 0,
    last_sync_at TEXT, last_attempt_at TEXT, last_error TEXT
  )''');
  await db.execute('''CREATE TABLE sync_conflicts (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    local_payload TEXT NOT NULL, remote_payload TEXT,
    reason TEXT NOT NULL, created_at TEXT NOT NULL, resolved_at TEXT
  )''');
  await db.execute('''CREATE TABLE sync_remote_versions (
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    server_revision INTEGER NOT NULL,
    PRIMARY KEY(entity_type, entity_id)
  )''');
  await db.execute('''CREATE TABLE sync_assets (
    id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
    local_path TEXT, storage_path TEXT, checksum TEXT,
    sync_status TEXT NOT NULL DEFAULT 'pending'
  )''');

  // Queue writes belong to the same SQLite transaction as the original mutation.
  // No HTTP, auth or retry operation participates in the counting transaction.
  String enqueue(String kind, String id) =>
      '''
    INSERT INTO sync_queue(entity_type, entity_id) VALUES ('$kind', $id)
    ON CONFLICT(entity_type, entity_id) DO UPDATE SET
      generation = generation + 1, attempts = 0, next_attempt_at = 0,
      state = 'pending', last_error = NULL, request_id = NULL, payload = NULL;
  ''';
  const local =
      '(SELECT applying_remote FROM sync_scope WHERE singleton = 1) = 0';
  await db.execute(
    '''CREATE TRIGGER sync_event_insert AFTER INSERT ON count_changes
    WHEN $local BEGIN
      INSERT INTO event_sync(event_id, user_id, device_id)
      SELECT NEW.id, user_id, device_id FROM sync_scope WHERE singleton = 1;
      ${enqueue('event', 'NEW.id')}
    END''',
  );
  // Project deletion hides history; immutable count events are never retracted.
  await db.execute(
    '''CREATE TRIGGER sync_project_insert AFTER INSERT ON projects
    WHEN $local BEGIN
      ${enqueue('project', 'NEW.id')}
      ${enqueue('order', "'projects'")}
    END''',
  );
  await db.execute(
    '''CREATE TRIGGER sync_project_metadata AFTER UPDATE OF name, imagePath, deletedAt ON projects
    WHEN $local AND (OLD.name IS NOT NEW.name OR OLD.imagePath IS NOT NEW.imagePath
      OR OLD.deletedAt IS NOT NEW.deletedAt) BEGIN
      ${enqueue('project', 'NEW.id')}
    END''',
  );
  await db.execute(
    '''CREATE TRIGGER sync_project_order AFTER UPDATE OF position, deletedAt ON projects
    WHEN $local AND (OLD.position IS NOT NEW.position OR OLD.deletedAt IS NOT NEW.deletedAt)
    BEGIN ${enqueue('order', "'projects'")} END''',
  );
  for (final verb in ['INSERT', 'UPDATE']) {
    await db.execute(
      '''CREATE TRIGGER sync_session_${verb.toLowerCase()} AFTER $verb ON sessions
      WHEN $local BEGIN ${enqueue('session', 'NEW.id')} END''',
    );
    await db.execute(
      '''CREATE TRIGGER sync_setting_${verb.toLowerCase()} AFTER $verb ON settings
      WHEN $local AND NEW.settingKey IN ('language','haptics','calendarUrl','forumUrl','noticeUrl')
      BEGIN ${enqueue('setting', 'NEW.settingKey')} END''',
    );
  }
  for (final pair in [
    ('project', 'projects'),
    ('event', 'count_changes'),
    ('session', 'sessions'),
  ]) {
    await db.execute('''INSERT INTO sync_queue(entity_type, entity_id)
      SELECT '${pair.$1}', id FROM ${pair.$2}''');
  }
  await db.execute(
    '''INSERT INTO sync_queue(entity_type, entity_id)
    SELECT 'setting', settingKey FROM settings
    WHERE settingKey IN ('language','haptics','calendarUrl','forumUrl','noticeUrl')''',
  );
  await db.insert('sync_queue', {
    'entity_type': 'order',
    'entity_id': 'projects',
  });
}
