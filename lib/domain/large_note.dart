import 'dart:convert';

List<String> splitNoteForEditing(String body) {
  List<dynamic> delta;
  try {
    final value = jsonDecode(body);
    delta =
        value is List && value.every((e) => e is Map && e.containsKey('insert'))
        ? value
        : [
            {'insert': body},
          ];
  } catch (_) {
    delta = [
      {'insert': body},
    ];
  }
  final chunks = <String>[];
  var runs = <Map<String, dynamic>>[];
  var length = 0;
  void flush() {
    if (runs.isNotEmpty) chunks.add(jsonEncode(runs));
    runs = [];
    length = 0;
  }

  for (final item in delta) {
    final insert = item['insert'];
    if (insert is String) {
      var start = 0;
      while (start < insert.length) {
        var end = (start + 16000 - length).clamp(start, insert.length);
        if (end < insert.length &&
            end > start &&
            insert.codeUnitAt(end - 1) >= 0xd800 &&
            insert.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
        if (end == start) {
          flush();
          continue;
        }
        runs.add({
          ...Map<String, dynamic>.from(item),
          'insert': insert.substring(start, end),
        });
        length += end - start;
        start = end;
        if (length >= 15999 || runs.length >= 256) flush();
      }
    } else {
      runs.add(Map<String, dynamic>.from(item));
      if (runs.length >= 256) flush();
    }
  }
  flush();
  return chunks.isEmpty ? ['[]'] : chunks;
}

String joinNoteChunks(List<String> chunks) =>
    jsonEncode([for (final chunk in chunks) ...jsonDecode(chunk) as List]);
List<int> searchNoteChunks(Map<String, dynamic> input) {
  final query = (input['query'] as String).toLowerCase();
  final chunks = List<String>.from(input['chunks']);
  return [
    for (var i = 0; i < chunks.length; i++)
      if ((jsonDecode(chunks[i]) as List)
          .map((e) => e['insert'] is String ? e['insert'] : '')
          .join()
          .toLowerCase()
          .contains(query))
        i,
  ];
}
