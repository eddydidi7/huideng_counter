/// A public post reference only; content is fetched again with current permissions.
final _postLink = RegExp(
  r'huideng://forum/post/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?![0-9a-zA-Z/-])',
);
String? sharedForumPostId(String text) => _postLink.firstMatch(text)?.group(1);
String? sharedForumSlug(String text) => RegExp(
  r'huideng://forum/post/[^\s?]+\?slug=([a-f0-9]{64})(?![a-f0-9])',
).firstMatch(text)?.group(1);
String forumShareText(String id, String title, {String? slug}) =>
    '${title.trim()}\nhuideng://forum/post/$id${slug == null ? '' : '?slug=$slug'}';
