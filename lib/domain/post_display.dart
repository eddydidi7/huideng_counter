import 'package:flutter/widgets.dart';

/// Display only: never writes generated text back to the author's title.
String getPostDisplayTitle(Map post) {
  final title = (post['title'] as String? ?? '').trim();
  if (title.isNotEmpty) return title;
  final body = (post['body'] as String? ?? '').trim().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  final letters = body.characters;
  return letters.length > 28 ? '${letters.take(28)}……' : body;
}

String compactPostCount(dynamic raw) {
  final n = (raw is num ? raw : 0).toInt();
  if (n < 1000) return '$n';
  if (n < 10000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  if (n < 100000000) {
    return '${(n / 10000).toStringAsFixed(n < 100000 ? 1 : 0)}万';
  }
  return '${(n / 100000000).toStringAsFixed(1)}亿';
}
