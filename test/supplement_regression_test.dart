import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/local/migrations/migration_v9.dart';
import 'package:huideng_counter/data/repositories/notes_repository.dart';
import 'package:huideng_counter/domain/chat_view.dart';
import 'package:huideng_counter/services/app_release.dart';

void main() {
  test('retired second favorite merges without losing note or queue', () async {
    sqfliteFfiInit();databaseFactory=databaseFactoryFfi;
    final db=await LocalDatabase.openAt(inMemoryDatabasePath);
    final repo=NotesRepository(db);
    final note=await repo.save({'body':'保留正文'});
    await db.update('notes',{'isFavorite2':1},where:'id=?',whereArgs:[note['id']]);
    await migrateToV9(db);
    final saved=await repo.get(note['id'] as String);
    expect(saved['body'],'保留正文');expect(saved['isFavorite'],1);expect(saved['isFavorite2'],0);
    expect((await db.query('note_outbox')).isNotEmpty,true);
    await repo.save({...saved,'isFavorite':0});expect(await repo.list(folder:'favorites'),isEmpty);
    await db.close();
  });
  test('recalled cached message is invisible even when still marked pending', () {
    expect(chatMessageVisible({'recalled_at':'2026-09-21','pending':true},null),false);
    expect(chatMessageVisible({'body':'live'},null),true);
  });
  test('release rejects HTTP and malformed hash', () {
    final row=<String,dynamic>{'version_code':48,'version_name':'1.0.47','apk_size':12,
      'download_url':'https://example.test/a.apk','release_notes':'修复','sha256':'a'*64,'published_at':'2026-09-21T00:00:00Z'};
    expect(AppRelease(row).force,false);
    expect(()=>AppRelease({...row,'download_url':'http://example.test/a.apk'}),throwsFormatException);
    expect(()=>AppRelease({...row,'sha256':'bad'}),throwsFormatException);
  });
}
