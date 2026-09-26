import 'package:sqflite/sqflite.dart';

Future<void> migrateToV8(Database db) async {
  await db.execute(
    'ALTER TABLE notes ADD COLUMN isFavorite2 INTEGER NOT NULL DEFAULT 0 CHECK(isFavorite2 IN (0,1))',
  );
  await db.execute('DROP TRIGGER IF EXISTS note_queue_update');
  await db.execute(
    '''CREATE TRIGGER note_queue_update AFTER UPDATE OF title,body,isPinned,isFavorite,isFavorite2,isArchived,deletedAt ON notes
 WHEN (SELECT applying_remote FROM sync_scope WHERE singleton=1)=0 BEGIN
 INSERT INTO note_outbox(note_id) VALUES(NEW.id) ON CONFLICT(note_id) DO UPDATE SET generation=generation+1;
 END''',
  );
}
