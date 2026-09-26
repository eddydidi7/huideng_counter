import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'chat_store.dart';

/// Durable account-scoped drafts; original user files are never removed.
class ForumDraftStore {
  ForumDraftStore(this.cache, this.directory);
  final ChatStore cache;
  final Directory directory;
  static Future<ForumDraftStore> open(String scope) async {
    final root = await getApplicationSupportDirectory();
    final folder = Directory(p.join(root.path, 'forum_draft_media'));
    await folder.create(recursive: true);
    return ForumDraftStore(await ChatStore.open(scope), folder);
  }

  Future<Map<String, dynamic>?> read(String key) async {
    final rows = await cache.read('compose:$key');
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> write(String key, Map<String, dynamic> draft) =>
      cache.write('compose:$key', [draft]);
  Future<String> importFile(String path) async {
    final target = p.join(
      directory.path,
      '${const Uuid().v4()}${p.extension(path)}',
    );
    await File(path).copy(target);
    return target;
  }

  Future<String> image(Uint8List bytes) async {
    final target = p.join(directory.path, '${const Uuid().v4()}.png');
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }
}
