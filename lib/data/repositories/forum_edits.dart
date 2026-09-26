import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../local/chat_store.dart';

/// Durable, account-scoped edits. A request is never mutated after submission.
class ForumEdits {
  final SupabaseClient client;
  final Future<ChatStore> Function(String) openStore;
  ForumEdits(this.client, {this.openStore = ChatStore.open});
  static final Map<String, Future<void>> _locks = {};
  String get userId {
    final user = client.auth.currentUser;
    if (user == null) {
      throw const AuthException('login_required');
    }
    return user.id;
  }

  Future<T> _serial<T>(Future<T> Function(String, ChatStore) run) async {
    final id = userId;
    final previous = _locks[id] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[id] = done.future;
    await previous;
    try {
      if (userId != id) throw const AuthException('login_required');
      return await run(id, await openStore(id));
    } finally {
      done.complete();
      if (identical(_locks[id], done.future)) _locks.remove(id);
    }
  }

  Future<List<Map<String, dynamic>>> pending() =>
      _serial((_, store) => store.read('forum_author_pending'));

  /// Local-only keys never sent to the server (keeps retries byte-identical).
  static const _localKeys = ['local_post', 'error', 'uploaded_paths'];

  /// Best-effort Storage cleanup. The delete policy refuses any file that is
  /// not the author's or that is still referenced, so this can never remove
  /// an image another post or saved item still uses.
  Future<void> removeFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await client.storage
          .from('forum-files')
          .remove(paths)
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  /// Media edits need forum_author_write_v2 (migration 202609250070).
  Future<bool> mediaEditingAvailable() async {
    try {
      await client
          .rpc('forum_author_write_v2', params: {'p_data': <String, dynamic>{}})
          .timeout(const Duration(seconds: 15));
      return true;
    } on PostgrestException catch (e) {
      return !const ['PGRST202', '42883'].contains(e.code);
    }
  }

  Future<void> save(
    Map<String, dynamic> post,
    String operation, {
    String? title,
    String? body,
    dynamic richBody,
    Map<String, dynamic>? jieyuan,
    List<Map<String, dynamic>>? attachments,
    List<String>? imageUrls,
    List<String> uploadedPaths = const [],
  }) => _serial((id, store) async {
    if (post['author_user_id'] != id) throw StateError('not_author');
    final rows = await store.read('forum_author_pending');
    if (rows.any((r) => r['post_id'] == post['id'])) {
      throw StateError('pending_edit_exists');
    }
    rows.add({
      'post_id': post['id'],
      'request_id': const Uuid().v4(),
      'operation': operation,
      'content_revision': post['content_revision'] ?? 0,
      'base_content': {
        'title': post['title'],
        'body': post['body'],
        'rich_body': post['rich_body'],
      },
      if (operation == 'edit') ...{
        'title': title,
        'body': body,
        'rich_body': richBody,
        'jieyuan': ?jieyuan,
        'attachments': ?attachments,
        'image_urls': ?imageUrls,
      },
      'local_post': post,
      if (uploadedPaths.isNotEmpty) 'uploaded_paths': uploadedPaths,
    });
    await store.write('forum_author_pending', rows);
  });

  Future<void> sync() => _serial((id, store) async {
    final rows = await store.read('forum_author_pending');
    for (final row in List<Map<String, dynamic>>.from(rows)) {
      if (userId != id) throw const AuthException('login_required');
      if (row['error'] == 'content_conflict') continue;
      try {
        final media = row.containsKey('attachments') ||
            row.containsKey('image_urls');
        final result = await client
            .rpc(
              media ? 'forum_author_write_v2' : 'forum_author_write_v1',
              params: {
                'p_data': Map<String, dynamic>.from(row)
                  ..removeWhere((k, _) => _localKeys.contains(k)),
              },
            )
            // Editing a full-length article sends the complete replacement
            // body, so it needs the same bounded write window as publishing.
            .timeout(const Duration(seconds: 120));
        rows.remove(row);
        // Only after the post no longer references them.
        if (result is Map && result['removed_paths'] is List) {
          await removeFiles(
            List<String>.from(result['removed_paths'] as List),
          );
        }
      } catch (e) {
        row['error'] = e is PostgrestException ? e.message : 'network_error';
      }
      await store.write('forum_author_pending', rows);
    }
  });

  // Explicitly discard a pending request; never silently overwrite a conflict.
  Future<void> discard(String postId) => _serial((_, store) async {
    final rows = await store.read('forum_author_pending');
    final uploaded = [
      for (final r in rows.where((r) => r['post_id'] == postId))
        ...List<String>.from(r['uploaded_paths'] as List? ?? []),
    ];
    rows.removeWhere((r) => r['post_id'] == postId);
    await store.write('forum_author_pending', rows);
    // New images uploaded for the discarded edit; the policy keeps any that
    // an already-synced edit made part of the post.
    await removeFiles(uploaded);
  });
}
