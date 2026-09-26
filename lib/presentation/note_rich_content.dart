import 'dart:convert';
import 'package:flutter_quill/flutter_quill.dart' as quill;

/// Notes made before the rich editor store plain text. Rich notes store the
/// standard Quill Delta JSON in the same body column, so no database migration
/// or data deletion is needed.
class NoteRichContent {
  static quill.Document documentFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is List &&
          decoded.every((item) => item is Map && item.containsKey('insert'))) {
        return quill.Document.fromJson(decoded);
      }
    } catch (_) {
      // Legacy plain text is intentionally handled below.
    }
    return quill.Document.fromJson([
      {'insert': '${body.replaceAll('\r\n', '\n')}\n'},
    ]);
  }

  static String encode(quill.Document document) =>
      jsonEncode(document.toDelta().toJson());

  static String plainText(String body) =>
      documentFromBody(body).toPlainText().trimRight();
}
