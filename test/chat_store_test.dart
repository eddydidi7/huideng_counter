import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/chat_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'chat cache and outbox isolate accounts; retries keep the same UUID',
    () async {
      final a = await ChatStore.openAt(inMemoryDatabasePath, 'alice');
      final b = ChatStore(a.db, 'bob');
      await a.write('rooms', [
        {'id': 'room', 'title': 'private'},
      ]);
      expect(await b.read('rooms'), isEmpty);
      await a.enqueue('fixed-id', 'room', 'offline message');
      await a.enqueue('fixed-id', 'room', 'must not replace');
      expect((await a.pending()).single['body'], 'offline message');
      expect(await b.pending(), isEmpty);
      await b.acknowledged('fixed-id');
      expect(await a.pending(), hasLength(1));
      final reopened = ChatStore(a.db, 'alice');
      expect(await reopened.pending(), hasLength(1));
      await a.acknowledged('fixed-id');
      expect(await a.pending(), isEmpty);
      expect(await a.read('rooms'), hasLength(1));
      await a.db.close();
    },
  );
}
