import 'package:sqflite/sqflite.dart';

Future<void> migrateToV5(Database db) async {
  await db.execute('''CREATE TABLE notes (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
    isPinned INTEGER NOT NULL DEFAULT 0 CHECK(isPinned IN (0,1)),
    isFavorite INTEGER NOT NULL DEFAULT 0 CHECK(isFavorite IN (0,1)),
    isArchived INTEGER NOT NULL DEFAULT 0 CHECK(isArchived IN (0,1)),
    version INTEGER NOT NULL CHECK(version > 0),
    createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, deletedAt TEXT,
    syncStatus TEXT NOT NULL DEFAULT 'pending'
  )''');
  await db.execute('''CREATE TABLE note_revisions (
    id TEXT PRIMARY KEY, noteId TEXT NOT NULL REFERENCES notes(id),
    payload TEXT NOT NULL, createdAt TEXT NOT NULL
  )''');
  await db.execute('CREATE INDEX notes_modified ON notes(updatedAt)');
  await db.execute(
    'CREATE INDEX note_versions ON note_revisions(noteId,createdAt)',
  );
}
