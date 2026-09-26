import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/domain/chat_view.dart';
import 'package:huideng_counter/services/chat_image.dart';
import 'package:image/image.dart' as img;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'v1 chat upgrade keeps queued message and cache; drafts and UI are account scoped',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huideng-chat-migration',
      );
      final path = '${directory.path}/chat.sqlite';
      final old = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE chat_cache (user_id TEXT NOT NULL,cache_key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(user_id,cache_key))',
          );
          await db.execute(
            'CREATE TABLE chat_outbox (user_id TEXT NOT NULL,id TEXT NOT NULL,room_id TEXT NOT NULL,body TEXT NOT NULL,attachment TEXT,created_at TEXT NOT NULL,PRIMARY KEY(user_id,id))',
          );
        },
      );
      await old.insert('chat_outbox', {
        'user_id': 'alice',
        'id': 'old-id',
        'room_id': 'r',
        'body': '原有消息',
        'created_at': '2026-09-17',
      });
      await old.insert('chat_cache', {
        'user_id': 'alice',
        'cache_key': 'rooms',
        'value': '[{"id":"r"}]',
      });
      await old.close();
      final store = await ChatStore.openAt(path, 'alice');
      try {
        expect((await store.pending()).single['body'], '原有消息');
        expect((await store.read('rooms')).single['id'], 'r');
        await store.failed('old-id', 'network');
        expect((await store.pending()).single['last_error'], 'network');
        await Future.wait([
          store.patchRoom('r', {'draft': '未发送正文'}),
          store.patchRoom('r', {'manualUnread': true}),
        ]);
        final view = (await store.roomViews())['r']!;
        expect(view['draft'], '未发送正文');
        expect(view['manualUnread'], true);
        await store.write('messages:r', [
          {'id': 'saved', 'created_at': '2026-09-17T10:00:00Z', 'body': '保留原文'},
        ]);
        await store.patchRoom('r', {'clearedThrough': '2026-09-17T10:00:00Z'});
        expect(await ChatStore(store.db, 'bob').roomViews(), isEmpty);
        await store.db.close();
        final reopened = await ChatStore.openAt(path, 'alice');
        expect((await reopened.roomViews())['r']!['draft'], '未发送正文');
        final retained = (await reopened.read('messages:r')).single;
        expect(retained['body'], '保留原文');
        expect(
          chatMessageVisible(
            retained,
            (await reopened.roomViews())['r']!['clearedThrough'] as String,
          ),
          false,
        );
        expect((await reopened.pending()).single['id'], 'old-id');
        await reopened.patchRoom('r', {'clearedThrough': null});
        expect(
          chatMessageVisible(
            retained,
            (await reopened.roomViews())['r']!['clearedThrough'] as String?,
          ),
          true,
        );
        await reopened.db.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('unread precedes newer read chats while pinned stays first', () {
    final rooms = <Map<String, dynamic>>[
      {'id': 'read', 'updated_at': '2026-09-17T12:00:00Z', 'unread': 0},
      {'id': 'unread', 'updated_at': '2026-09-17T10:00:00Z', 'unread': 1},
      {'id': 'pin', 'updated_at': '2026-09-17T09:00:00Z', 'pinned': true},
    ];
    expect(visibleChatRooms(rooms, {}).map((r) => r['id']), [
      'pin',
      'unread',
      'read',
    ]);
    expect(
      chatMessageVisible({
        'created_at': '2026-09-17T10:00:01Z',
      }, '2026-09-17T10:00:00Z'),
      true,
    );
    expect(
      chatMessageVisible({
        'created_at': '2026-09-17T09:00:00Z',
        'pending': true,
      }, '2026-09-17T10:00:00Z'),
      true,
    );
    expect(
      chatPreview(
        {'preview': '旧消息', 'updated_at': '2026-09-17T09:00:00Z'},
        {'clearedThrough': '2026-09-17T10:00:00Z'},
      ),
      '',
    );
  });
  test(
    'pinned order, manual unread and hidden conversations return only on newer activity',
    () {
      final rooms = <Map<String, dynamic>>[
        {'id': 'a', 'updated_at': '2026-09-17T10:00:00Z', 'unread': 3},
        {
          'id': 'b',
          'updated_at': '2026-09-17T09:00:00Z',
          'pinned': true,
          'unread': 0,
        },
        {'id': 'c', 'updated_at': '2026-09-17T11:00:00Z', 'unread': 2},
      ];
      final views = <String, Map<String, dynamic>>{
        'a': {'hiddenThrough': '2026-09-17T10:00:00Z'},
        'b': {'manualUnread': true},
      };
      expect(visibleChatRooms(rooms, views).map((r) => r['id']), ['b', 'c']);
      expect(roomUnread(rooms[1], views['b']), 1);
      rooms[0]['updated_at'] = '2026-09-17T12:00:00Z';
      expect(visibleChatRooms(rooms, views).map((r) => r['id']), [
        'b',
        'a',
        'c',
      ]);
    },
  );
  test('image compression bounds dimensions and produces a readable JPEG', () {
    final image = img.Image(width: 2200, height: 400);
    final result = compressChatImage(img.encodePng(image));
    final decoded = img.decodeJpg(result)!;
    expect(decoded.width, 1600);
    expect(decoded.height, lessThanOrEqualTo(1600));
    expect(result.length, lessThan(10 * 1024 * 1024));
  });
}
