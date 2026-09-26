import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../data/local/chat_store.dart';

class ChatStickerStore {
  ChatStickerStore(this.store, {this.directoryOverride});
  final Directory? directoryOverride;
  final ChatStore store;
  Future<List<Map<String, dynamic>>> list() async {
    final saved = await store.read('favorite_stickers_v1');
    final hidden = (await store.read(
      'hidden_builtin_stickers_v1',
    )).map((s) => s['id']).toSet();
    final bundled =
        jsonDecode(await rootBundle.loadString('assets/stickers/manifest.json'))
            as List;
    return [
      ...saved,
      ...bundled
          .map((s) => Map<String, dynamic>.from(s))
          .where((s) => !hidden.contains(s['id'])),
    ];
  }

  Future<String> localPath(Map<String, dynamic> item) async {
    if (item['path'] != null) return item['path'] as String;
    final bytes = await rootBundle.load(item['asset'] as String);
    final root = directoryOverride ?? await getApplicationSupportDirectory();
    final dir = await Directory(
      '${root.path}/chat_stickers/${store.userId}',
    ).create(recursive: true);
    final file = File('${dir.path}/${item['id']}.png');
    if (!await file.exists()) {
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  }

  static String extension(List<int> b) {
    if (b.length < 12) throw const FormatException('IMAGE_INVALID');
    if (b[0] == 137 && b[1] == 80 && b[2] == 78 && b[3] == 71) return 'png';
    if (b[0] == 255 && b[1] == 216 && b[2] == 255) return 'jpg';
    if (String.fromCharCodes(b.take(6)) == 'GIF89a' ||
        String.fromCharCodes(b.take(6)) == 'GIF87a') {
      return 'gif';
    }
    if (String.fromCharCodes(b.take(4)) == 'RIFF' &&
        String.fromCharCodes(b.skip(8).take(4)) == 'WEBP') {
      return 'webp';
    }
    throw const FormatException('IMAGE_INVALID');
  }

  Future<void> add(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw const FormatException('IMAGE_SIZE');
    }
    final ext = extension(bytes);
    final id = sha256.convert(bytes).toString();
    final root = directoryOverride ?? await getApplicationSupportDirectory();
    final directory = await Directory(
      '${root.path}/chat_stickers/${store.userId}',
    ).create(recursive: true);
    final path = '${directory.path}/$id.$ext';
    await File(path).writeAsBytes(bytes, flush: true);
    final previous = await store.read('favorite_stickers_v1');
    await store.write('favorite_stickers_v1', [
      {'id': id, 'path': path},
      ...previous.where((s) => s['id'] != id),
    ]);
  }

  Future<void> remove(String id) async {
    if (id.startsWith('builtin_')) {
      final hidden = await store.read('hidden_builtin_stickers_v1');
      await store.write('hidden_builtin_stickers_v1', [
        ...hidden.where((s) => s['id'] != id),
        {'id': id},
      ]);
      return;
    }
    // Remove the favorite only; never delete a file still queued for sending.
    final previous = await store.read('favorite_stickers_v1');
    await store.write(
      'favorite_stickers_v1',
      previous.where((s) => s['id'] != id).toList(),
    );
  }
}
