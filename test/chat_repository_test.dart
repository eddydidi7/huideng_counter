import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';
import 'package:huideng_counter/data/repositories/chat_repository.dart';

class LostReply extends ChatRemote {
  LostReply()
    : super(
        SupabaseClient('https://example.invalid', 'public-test-key'),
        'alice',
      );
  final received = <String, Map<String, dynamic>>{};
  bool loseReply = true, wrongUser = false;
  @override
  void checkUser() {
    if (wrongUser) throw const AuthException('changed account');
  }

  @override
  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    checkUser();
    final saved = received.putIfAbsent(
      data['id'] as String,
      () => {
        ...data,
        'sender_id': 'alice',
        'created_at': '2026-09-17T01:00:00Z',
      },
    );
    if (loseReply) {
      loseReply = false;
      throw const SocketException('lost response');
    }
    return saved;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'lost server reply retains queue and retry deduplicates by UUID',
    () async {
      final store = await ChatStore.openAt(inMemoryDatabasePath, 'alice');
      final remote = LostReply();
      final repo = ChatRepository(store, remote);
      await store.enqueue('message-uuid', 'room', 'hello');
      await expectLater(repo.flush(), throwsA(isA<SocketException>()));
      expect(await store.pending(), hasLength(1));
      expect(remote.received, hasLength(1));
      await repo.flush();
      expect(await store.pending(), isEmpty);
      expect(remote.received, hasLength(1));
      expect((await store.read('messages:room')).single['body'], 'hello');
      await store.enqueue('next-uuid', 'room', 'private');
      remote.wrongUser = true;
      await expectLater(repo.flush(), throwsA(isA<AuthException>()));
      expect(await store.pending(), hasLength(1));
      expect(remote.received, hasLength(1));
      await remote.client.dispose();
      await store.db.close();
    },
  );
}
