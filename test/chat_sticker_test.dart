import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/services/chat_sticker_store.dart';
import 'package:huideng_counter/domain/chat_emojis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test('emoji catalogue has over 250 unique entries', () {
    expect(chatEmojiSet.length, greaterThan(250));
    expect(chatEmojiSet.contains('🙏'), isTrue);
    expect(chatEmojiSet.contains('❤️'), isTrue);
  });
  test(
    'favorites persist, deduplicate and isolate users without removing files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huideng_sticker_test_',
      );
      final a = await ChatStore.openAt(inMemoryDatabasePath, 'alice');
      final b = ChatStore(a.db, 'bob');
      final favorites = ChatStickerStore(a, directoryOverride: directory);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      try {
        final bundled = await favorites.list();
        expect(bundled, hasLength(29));
        for (final sticker in bundled) {
          final asset = await rootBundle.load(sticker['asset'] as String);
          expect(asset.lengthInBytes, lessThanOrEqualTo(10 * 1024 * 1024));
          expect(
            ChatStickerStore.extension(
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
            ),
            'png',
          );
        }
        final materialized = await favorites.localPath(bundled.first);
        expect(await File(materialized).exists(), isTrue);
        await favorites.remove(bundled.first['id'] as String);
        expect(await favorites.list(), hasLength(28));
        expect(
          await ChatStickerStore(b, directoryOverride: directory).list(),
          hasLength(29),
        );
        await favorites.add(bytes);
        await favorites.add(bytes);
        final items = await a.read('favorite_stickers_v1');
        expect(items, hasLength(1));
        expect(await b.read('favorite_stickers_v1'), isEmpty);
        expect(
          await ChatStore(a.db, 'alice').read('favorite_stickers_v1'),
          hasLength(1),
        );
        final file = File(items.single['path'] as String);
        expect(await file.readAsBytes(), bytes);
        await favorites.remove(items.single['id'] as String);
        expect(await a.read('favorite_stickers_v1'), isEmpty);
        expect(await file.exists(), isTrue);
        await favorites.remove('builtin_test');
        expect(await a.read('hidden_builtin_stickers_v1'), hasLength(2));
        expect(await b.read('hidden_builtin_stickers_v1'), isEmpty);
      } finally {
        await a.db.close();
        // Only the unique temporary directory created by this test is removed.
        await directory.delete(recursive: true);
      }
    },
  );
}
