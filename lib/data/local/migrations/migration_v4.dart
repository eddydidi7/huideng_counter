import 'package:sqflite/sqflite.dart';

Future<void> migrateToV4(Database db) async {
  await db.execute('ALTER TABLE event_sync ADD COLUMN payload TEXT');
  await db.execute(
    'CREATE TABLE cloud_projects(project_id TEXT PRIMARY KEY REFERENCES projects(id), image_key TEXT)',
  );
  await db.execute(
    'CREATE TABLE cloud_documents(kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(kind,id))',
  );
  await db.execute(
    'CREATE TABLE ledger_balances(project_id TEXT PRIMARY KEY REFERENCES projects(id), balance TEXT NOT NULL)',
  );
  await db.execute(
    'INSERT INTO ledger_balances SELECT id, CAST(total AS TEXT) FROM projects',
  );
  await db.execute(
    'CREATE TABLE guest_import_claims(project_id TEXT PRIMARY KEY, user_id TEXT NOT NULL)',
  );
  for (final verb in ['INSERT', 'UPDATE OF imagePath']) {
    final label = verb.startsWith('INSERT') ? 'insert' : 'update';
    await db.execute(
      '''CREATE TRIGGER sync_image_$label AFTER $verb ON projects
      WHEN (SELECT applying_remote FROM sync_scope)=0 AND NEW.imagePath IS NOT NULL
      BEGIN INSERT INTO sync_queue(entity_type,entity_id) VALUES('image',NEW.id)
      ON CONFLICT(entity_type,entity_id) DO UPDATE SET generation=generation+1,
      attempts=0,next_attempt_at=0,state='pending',request_id=NULL,payload=NULL; END''',
    );
  }
  await db.execute(
    "INSERT INTO sync_queue(entity_type,entity_id) SELECT 'image',id FROM projects WHERE imagePath IS NOT NULL",
  );
}
