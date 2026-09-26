import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/forum_share.dart';

void main() {
  const id = '12345678-1234-1234-1234-123456789abc';
  test('shared post reference survives surrounding draft and message text', () {
    final value = forumShareText(id, '学修交流');
    expect(sharedForumPostId('已有草稿\n$value'), id);
  });
  test('malformed references and unrelated URLs cannot open a post', () {
    expect(sharedForumPostId('https://example.com/post/$id'), isNull);
    expect(sharedForumPostId('huideng://forum/post/not-a-uuid'), isNull);
    expect(sharedForumPostId('huideng://forum/post/${id}abc'), isNull);
  });
}
