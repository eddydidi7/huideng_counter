import 'dart:convert';
import 'dart:io';
import 'package:huideng_counter/data/local/forum_draft_store.dart';
import 'package:huideng_counter/data/local/chat_store.dart';

class NoChatStore implements ChatStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryDraft extends ForumDraftStore {
  MemoryDraft() : super(NoChatStore(), Directory('.'));
  final rows = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => rows[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    rows[key] = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)));
  }
}
