import 'package:sqflite/sqflite.dart';

/// Merge the retired second list into the existing favorite flag. Keep the
/// legacy column for old backups/sync payloads; it no longer drives a UI list.
Future<void> migrateToV9(Database db) async {
  await db.execute(
    'UPDATE notes SET isFavorite=1,isFavorite2=0,version=version+1, '
    "syncStatus='pending',updatedAt=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE isFavorite2=1",
  );
}
