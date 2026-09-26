import 'dart:convert';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/note_rich_content.dart';

void main() {
  test('legacy plain text opens unchanged as a Quill document', () {
    final document = NoteRichContent.documentFromBody('旧笔记\n第二行');
    expect(document.toPlainText(), '旧笔记\n第二行\n');
    expect(NoteRichContent.plainText('旧笔记\n第二行'), '旧笔记\n第二行');
  });

  test('rich formatting survives encode and reopen', () {
    final document = NoteRichContent.documentFromBody('格式正文');
    document.format(0, 2, quill.Attribute.bold);
    final stored = NoteRichContent.encode(document);
    expect(jsonDecode(stored), isA<List>());
    final reopened = NoteRichContent.documentFromBody(stored);
    expect(reopened.toPlainText().trim(), '格式正文');
    expect(NoteRichContent.encode(reopened), stored);
  });

  test('malformed historic body remains readable text', () {
    expect(NoteRichContent.plainText('[not a delta'), '[not a delta');
  });
}
