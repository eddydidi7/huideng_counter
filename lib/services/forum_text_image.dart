import '../domain/post_display.dart';
import 'dart:typed_data';
import 'forum_card_layout.dart';

String forumAutomaticTitle(String body) => getPostDisplayTitle({'body': body});

/// Compatibility API for callers requesting only the first page.
Future<Uint8List> renderForumTextImage(String text) async {
  final style = ForumCardStyle();
  final pages = paginateForumCard(text, style);
  return renderForumCardPage(pages.first, style, 0, pages.length);
}
