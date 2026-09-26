import 'package:flutter/foundation.dart';
import '../local/home_message_cache.dart';
import '../remote/forum_remote.dart';
import '../remote/forum_social.dart';
import 'forum_edits.dart';

class ForumFeed {
  final List<Map<String, dynamic>> items;
  final bool cached, hasMore;
  const ForumFeed(this.items, {this.cached = false, this.hasMore = false});
}

class ForumRepository {
  final ForumRemote? remote;
  final HomeMessageCache cache;
  ForumRepository(this.remote, this.cache);
  bool get signedIn => remote?.client.auth.currentSession != null;
  Future<List<Map<String, dynamic>>> sections() async {
    if (remote == null) throw StateError('unconfigured');
    return remote!.sections();
  }

  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async {
    if (remote == null) throw StateError('unconfigured');
    return remote!.action(action, data);
  }

  Future<ForumFeed> feed({
    String search = '',
    String category = '',
    String sort = 'latest',
    int offset = 0,
    Map<String, dynamic>? after,
  }) async {
    if (remote?.client.auth.currentUser != null) {
      try {
        await ForumEdits(remote!.client).sync();
      } catch (_) {}
    }
    if (sort == 'following') {
      // Followed authors only, newest first (keyset pagination).
      if (remote == null) throw StateError('unconfigured');
      final rows = await ForumSocial(remote!.client).followingFeed(
        after: after,
        limit: 21,
      );
      final items = await Future.wait(rows.take(20).map(remote!.media));
      return ForumFeed(items, hasMore: rows.length > 20);
    }
    if (sort == 'mine' ||
        sort == 'bookmarks' ||
        sort == 'my_replies' ||
        sort == 'completed') {
      final result = await action(sort == 'completed' ? 'mine' : sort, {});
      final rows = (result['items'] as List).map(
        (r) => Map<String, dynamic>.from(r as Map),
      );
      final query = search.toLowerCase();
      return ForumFeed(
        rows
            .where(
              (r) =>
                  (category.isEmpty || r['category_id'] == category) &&
                  (sort != 'completed' ||
                      r['jieyuan']?['status'] == 'completed') &&
                  (query.isEmpty ||
                      [
                        r['title'],
                        r['body'],
                        r['author_name'],
                        ...(r['tags'] as List? ?? []),
                      ].join(' ').toLowerCase().contains(query)),
            )
            .toList(),
      );
    }
    final cacheable = search.isEmpty && category.isEmpty && offset == 0;
    try {
      if (remote == null) throw StateError('unconfigured');
      final rows = await remote!.feed(
        search: search,
        category: category,
        sort: sort,
        offset: offset,
      );
      final items = rows.take(20).toList();
      if (cacheable) {
        try {
          await cache.write({
            'items': items,
            'sort': sort,
            'saved_at': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (error) {
          debugPrint('Forum cache write failed: ${error.runtimeType}');
        }
      }
      return ForumFeed(items, hasMore: rows.length > 20);
    } catch (_) {
      if (cacheable) {
        final value = await cache.read();
        if (value != null && value['sort'] == sort) {
          return ForumFeed(
            (value['items'] as List)
                .map((r) => Map<String, dynamic>.from(r as Map))
                .toList(),
            cached: true,
          );
        }
      }
      rethrow;
    }
  }
}
