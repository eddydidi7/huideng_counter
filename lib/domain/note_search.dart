import 'note_reader.dart';

/// Searches rendered text, not Delta JSON attributes or attachment payloads.
Map<String, Object?>? matchNoteText(Map<String, String> input) {
  final query = input['query']!.trim();
  if (query.isEmpty) return null;
  final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
  final body = input['body'] ?? '';
  final text = StringBuffer();
  for (final paragraph in readerParagraphs(body)) {
    for (final run in paragraph.runs) {
      text.write(run['insert'] is String ? run['insert'] : '\uFFFC');
    }
    if (body.length < 100000) text.write('\n');
  }
  final plain = text.toString();
  final match = pattern.firstMatch(plain);
  if (match == null && !pattern.hasMatch(input['title'] ?? '')) return null;
  final offset = match?.start ?? 0;
  final start = (offset - 45).clamp(0, plain.length);
  final end = (offset + query.length + 100).clamp(start, plain.length);
  return {
    'offset': offset,
    'snippet': plain.substring(start, end).replaceAll('\uFFFC', '').trim(),
  };
}
