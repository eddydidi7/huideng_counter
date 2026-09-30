import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/note_search.dart';

void main() {
  test('searches full body beyond list preview and supports literal query', () {
    final prefix = '正文' * 60000;
    final result = matchNoteText({'query': 'A+B%', 'body': '${prefix}a+b%结尾'});
    expect(result?['offset'], prefix.length);
    expect(result?['snippet'], contains('a+b%'));
  });
  test('matches across formatting runs and counts embedded offsets', () {
    final body = jsonEncode([
      {
        'insert': {'image': 'secret-image-url'},
      },
      {
        'insert': '第一行\n关键',
        'attributes': {'bold': true},
      },
      {'insert': '词正文\n'},
    ]);
    expect(matchNoteText({'query': '关键词', 'body': body})?['offset'], 5);
    expect(matchNoteText({'query': 'secret-image-url', 'body': body}), isNull);
    expect(matchNoteText({'query': 'bold', 'body': body}), isNull);
  });
  test('title matches, missing and blank queries', () {
    expect(
      matchNoteText({'query': '标题', 'title': '我的标题', 'body': '正文'})?['offset'],
      0,
    );
    expect(matchNoteText({'query': '不存在', 'body': '正文'}), isNull);
    expect(matchNoteText({'query': '  ', 'body': '正文'}), isNull);
  });
}
