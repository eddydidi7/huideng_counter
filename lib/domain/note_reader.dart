import 'dart:convert';

class ReaderParagraph {
  final List<Map<String, dynamic>> runs;
  ReaderParagraph(this.runs);
  late final String text = runs
      .map((r) => r['insert'] is String ? r['insert'] as String : '')
      .join();
  String get anchor =>
      text.trim().length > 100 ? text.trim().substring(0, 100) : text.trim();
}

List<ReaderParagraph> readerParagraphs(String body) {
  List<dynamic>? delta;
  try {
    final parsed = jsonDecode(body);
    if (parsed is List &&
        parsed.every((e) => e is Map && e.containsKey('insert'))) {
      delta = parsed;
    }
  } catch (_) {}
  delta ??= [
    {'insert': body.replaceAll('\r\n', '\n')},
  ];
  if (body.length < 100000) {
    final blocks = <ReaderParagraph>[];
    var runs = <Map<String, dynamic>>[];
    for (final item in delta) {
      final insert = item['insert'];
      if (insert is String) {
        final pieces = insert.split('\n');
        for (var i = 0; i < pieces.length; i++) {
          if (pieces[i].isNotEmpty) {
            runs.add({'insert': pieces[i], 'attributes': item['attributes']});
          }
          if (i < pieces.length - 1) {
            blocks.add(ReaderParagraph(runs));
            runs = [];
          }
        }
      } else if (insert is Map) {
        runs.add({'insert': Map<String, dynamic>.from(insert)});
      }
    }
    if (runs.isNotEmpty) blocks.add(ReaderParagraph(runs));
    return blocks.isEmpty ? [ReaderParagraph([])] : blocks;
  }
  final blocks = <ReaderParagraph>[];
  var runs = <Map<String, dynamic>>[];
  var length = 0;
  void flush() {
    if (runs.isNotEmpty) blocks.add(ReaderParagraph(runs));
    runs = [];
    length = 0;
  }

  for (final dynamic item in delta) {
    final insert = item['insert'];
    if (insert is String) {
      var offset = 0;
      while (offset < insert.length) {
        var end = (offset + 2048 - length).clamp(offset, insert.length);
        if (end < insert.length &&
            end > offset &&
            insert.codeUnitAt(end - 1) >= 0xd800 &&
            insert.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
        if (end == offset) {
          flush();
          continue;
        }
        final localNewline = insert.substring(offset, end).lastIndexOf('\n');
        final newline = localNewline < 0 ? -1 : offset + localNewline;
        if (newline >= offset && newline - offset + length >= 512) {
          end = newline + 1;
        }
        runs.add({
          'insert': insert.substring(offset, end),
          'attributes': item['attributes'],
        });
        length += end - offset;
        offset = end;
        if (length >= 2047 ||
            runs.length >= 64 ||
            (length >= 512 && insert[end - 1] == '\n')) {
          flush();
        }
      }
    } else if (insert is Map) {
      runs.add({'insert': Map<String, dynamic>.from(insert)});
      if (runs.length >= 64) flush();
    }
  }
  flush();
  return blocks.isEmpty ? [ReaderParagraph([])] : blocks;
}

double normalizeReaderRate(double value) =>
    (value.clamp(.3, 3) * 10).round() / 10.0;

int restoreReaderAnchor(List<ReaderParagraph> paragraphs, dynamic saved) {
  if (saved is! Map) return 0;
  final previous = (saved['index'] as num? ?? 0).toInt().clamp(
    0,
    paragraphs.length - 1,
  );
  final anchor = saved['anchor'];
  if (anchor is String && anchor.isNotEmpty) {
    final matches = <int>[
      for (var i = 0; i < paragraphs.length; i++)
        if (paragraphs[i].anchor == anchor) i,
    ];
    if (matches.isNotEmpty) {
      matches.sort(
        (a, b) => (a - previous).abs().compareTo((b - previous).abs()),
      );
      return matches.first;
    }
  }
  return previous;
}

int readerSpeechEnd(String text, int start) {
  var end = (start + 900).clamp(0, text.length);
  if (end < text.length) {
    final slice = text.substring(start, end);
    final punctuation = RegExp(r'[。！？.!?；;\n]').allMatches(slice).lastOrNull;
    if (punctuation != null && punctuation.end > 200) {
      end = start + punctuation.end;
    }
    if (end > start &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
  }
  return end;
}
