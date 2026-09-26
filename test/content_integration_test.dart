import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/services/content_transfer.dart';
import 'package:huideng_counter/domain/forum_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'note copies get new IDs, preserve source and never carry signed URLs',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final app = AppController(SqliteCounterRepository(db));
      final transfer = ContentTransfer(app);
      try {
        final source = {
          'id': 'source-post',
          'title': '学修',
          'body': '原文',
          'attachments': [
            {
              'id': 'f',
              'path': 'owner/f',
              'kind': 'image',
              'url': 'https://signed.test/private-token',
            },
          ],
        };
        final a = await transfer.postToNote(source),
            b = await transfer.postToNote(source);
        expect(a['id'], isNot(b['id']));
        expect(a['source_post_id'], 'source-post');
        expect(a['source_meta'].toString(), isNot(contains('private-token')));
        await transfer.notes.save({...a, 'body': '自己的注释'});
        expect(source['body'], '原文');
        final merged = await transfer.messagesToNote(
          'room',
          '聊天摘录',
          [
            {
              'id': '2',
              'created_at': '2026-09-18T11:00:00Z',
              'sender_id': 'a',
              'body': '后',
            },
            {
              'id': '1',
              'created_at': '2026-09-18T10:00:00Z',
              'sender_id': 'b',
              'body': '先',
              'attachment_path': 'b/file',
            },
          ],
          [
            {'user_id': 'b', 'nickname': '乙'},
          ],
        );
        expect(
          merged['body'].toString().indexOf('先'),
          lessThan(merged['body'].toString().indexOf('后')),
        );
        expect(
          jsonDecode(
            merged['source_meta'] as String,
          )['messages'][0]['attachment_path'],
          'b/file',
        );
      } finally {
        app.dispose();
        await db.close();
      }
    },
  );
  test(
    'practice queue includes only subsequent local taps, not imported remote events',
    () async {
      final db = await LocalDatabase.openAt(inMemoryDatabasePath);
      final repo = SqliteCounterRepository(db);
      try {
        await repo.saveProject('念佛', null);
        final p = (await repo.projects()).single;
        final session = await repo.beginSession(p.id);
        await repo.increment(session);
        expect(await db.query('practice_outbox'), isEmpty);
        await db.insert('practice_links', {
          'project_id': p.id,
          'practice_id': 'practice',
          'group_id': 'group',
        });
        await repo.increment(session);
        expect(await db.query('practice_outbox'), hasLength(1));
        await db.rawUpdate('UPDATE sync_scope SET applying_remote=1');
        await repo.increment(session);
        expect(await db.query('practice_outbox'), hasLength(1));
        await db.rawUpdate('UPDATE sync_scope SET applying_remote=0');
        await db.delete('practice_links');
        await repo.increment(session);
        expect(await db.query('practice_outbox'), hasLength(1));
      } finally {
        await db.close();
      }
    },
  );
  test('link-only chat card retains capability token', () {
    const id = '12345678-1234-1234-1234-123456789abc';
    final slug = 'a' * 64;
    final text = forumShareText(id, '标题', slug: slug);
    expect(sharedForumPostId(text), id);
    expect(sharedForumSlug(text), slug);
  });
}
