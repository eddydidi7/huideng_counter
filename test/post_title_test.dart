import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:huideng_counter/domain/post_title.dart';
import 'package:huideng_counter/domain/post_display.dart';

void main() {
  test('supplied title and body are untouched', () {
    final value = prepareNewPostText('我的标题……', '  原文。\n正文继续。  ');
    expect(value.title, '我的标题……');
    expect(value.body, '  原文。\n正文继续。  ');
    expect(value.consumed, 0);
  });
  test(
    'requested example consumes the complete opening sentence exactly once',
    () {
      const title = '很多人深有体会，平时上师说成千上万次，不如一次打击刻骨铭心';
      const rest = '所以，亲历无常和痛苦，反而成了进步的阶梯……';
      const original = '$title。$rest';
      final value = prepareNewPostText('', original);
      expect(value.title, title);
      expect(value.body, rest);
      expect(original.substring(value.consumed), rest);
      final retry = prepareNewPostText('', original);
      expect(retry.body, rest);
      final renamed = prepareNewPostText('修改后的标题', value.body);
      expect(renamed.body, rest);
    },
  );
  test('short first paragraph, CRLF and title-only post', () {
    final value = prepareNewPostText('', '  第一段很短\r\n\r\n第二段不动\n第三段。');
    expect(value.title, '第一段很短');
    expect(value.body, '第二段不动\n第三段。');
    expect(prepareNewPostText('', '只有一句。').body, '');
    expect(prepareNewPostText('', '标题....').title, '标题');
    expect(prepareNewPostText('', '标题……').title, '标题');
    expect(prepareNewPostText('', '').title, '');
  });
  test(
    'long sentence prefers a clause boundary, never a half word or added ellipsis',
    () {
      final value = prepareNewPostText('', '${'甲' * 20}，${'乙' * 90}。剩余');
      expect(value.title, '甲' * 20);
      expect(value.body, '${'乙' * 90}。剩余');
      final unbroken = '字' * 200;
      final safe = prepareNewPostText('', unbroken);
      expect(safe.title, '文字分享');
      expect(safe.body, unbroken);
      expect(safe.consumed, 0);
      final emoji = prepareNewPostText('', '${'👨‍👩‍👧‍👦' * 5}\n继续');
      expect(emoji.title, '👨‍👩‍👧‍👦' * 5);
      expect(emoji.body, '继续');
    },
  );
  test('rich Delta slicing retains body attributes and embedded media', () {
    final doc = quill.Document.fromJson([
      {
        'insert': '开头标题',
        'attributes': {'bold': true},
      },
      {'insert': '。\n'},
      {
        'insert': '正文',
        'attributes': {'italic': true},
      },
      {
        'insert': {'image': 'https://example.test/image.png'},
      },
      {'insert': '\n'},
    ]);
    final original = doc.toDelta().toJson();
    final value = prepareNewPostText('', doc.toPlainText().trimRight());
    expect(value.title, '开头标题');
    final delta = doc.toDelta().slice(value.consumed).toJson();
    expect(delta.first, {
      'insert': '正文',
      'attributes': {'italic': true},
    });
    expect(delta[1]['insert'], {'image': 'https://example.test/image.png'});
    expect(doc.toDelta().toJson(), original);
    doc.close();
  });
  test('display fallback never mutates historical body', () {
    final old = {'title': '', 'body': '旧帖首句。原有正文'};
    expect(getPostDisplayTitle(old), '旧帖首句');
    expect(old['body'], '旧帖首句。原有正文');
  });
}
