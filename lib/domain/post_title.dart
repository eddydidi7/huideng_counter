import 'package:flutter/widgets.dart';

class PostTitleText {
  const PostTitleText(this.title, this.body, this.consumed);
  final String title, body;

  /// UTF-16 prefix length, also usable with a Quill Delta slice.
  final int consumed;
}

/// Only call when preparing a new post. Never apply to an existing post edit.
PostTitleText prepareNewPostText(String title, String body) {
  if (title.trim().isNotEmpty || body.trim().isEmpty) {
    return PostTitleText(title, body, 0);
  }
  final text = body.trimLeft();
  var prefix = '', runes = 0;
  // Bound work for multi-million-character notes and respect the SQL 160 limit.
  for (final character in text.characters) {
    final count = character.runes.length;
    if (runes + count > 160) break;
    prefix += character;
    runes += count;
  }
  final sentence = RegExp(r'[。！？!?；;\r\n]|\.(?=\s|$)').firstMatch(prefix);
  final clauses = RegExp(r'[，,、：:]|\s+').allMatches(prefix).toList();
  bool short(int end) => prefix.substring(0, end).runes.length <= 60;
  final shortClauses = clauses.where((m) => short(m.end));
  final int end;
  if (sentence != null && short(sentence.end)) {
    end = sentence.end;
  } else if (text == prefix && short(prefix.length)) {
    end = prefix.length;
  } else if (shortClauses.isNotEmpty) {
    end = shortClauses.last.end;
  } else if (sentence != null) {
    end = sentence.end;
  } else if (text == prefix) {
    end = prefix.length;
  } else if (clauses.isNotEmpty) {
    end = clauses.first.end;
  } else {
    // No complete boundary fits: do not cut a word or discard original text.
    return PostTitleText('文字分享', body, 0);
  }
  final extracted = prefix.substring(0, end);
  final heading = extracted.trim().replaceFirst(
    RegExp(r'[。！？!?；;，,、：:.…\s]+$'),
    '',
  );
  // An embedded image is not text and must never disappear into the title.
  if (heading.isEmpty || extracted.contains('\uFFFC')) {
    return PostTitleText('文字分享', body, 0);
  }
  final remainder = text.substring(end).trimLeft();
  return PostTitleText(heading, remainder, body.length - remainder.length);
}
