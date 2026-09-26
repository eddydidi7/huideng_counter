import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/note_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('TXT and Markdown retain Chinese, formatting and images', () {
    final ops = [
      {'insert': '修行笔记'},
      {
        'insert': '\n',
        'attributes': {'header': 2},
      },
      {
        'insert': '慈悲',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
      {
        'insert': {'image': 'data:image/png;base64,abc'},
      },
      {'insert': '\n'},
    ];
    expect(NoteExport.plain(ops), contains('修行笔记\n慈悲\n'));
    expect(NoteExport.markdown(ops), contains('## 修行笔记\n**慈悲**'));
    expect(
      NoteExport.markdown(ops),
      contains('![图片](<data:image/png;base64,abc>)'),
    );
  });
  test('long multilingual note exports a multipage PDF offline', () async {
    final bytes = await NoteExport.pdf([
      {'insert': List.filled(180, '文殊计数器 笔记 Test 123').join('\n')},
    ]);
    expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
    expect(bytes.length, greaterThan(1000));
    final raw = latin1.decode(bytes);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, greaterThan(1));
  });
}
