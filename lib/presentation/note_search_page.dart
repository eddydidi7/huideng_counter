import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import '../domain/note_search.dart';
import 'note_reader_page.dart';

class NoteSearchPage extends StatefulWidget {
  const NoteSearchPage({super.key, required this.app});
  final AppController app;
  @override
  State<NoteSearchPage> createState() => _NoteSearchPageState();
}

class _NoteSearchPageState extends State<NoteSearchPage> {
  final controller = TextEditingController();
  final results = <Map<String, Object?>>[];
  Timer? debounce;
  int generation = 0;
  bool loading = false;
  bool opening = false;
  String? error;
  NotesRepository get repository =>
      NotesRepository((widget.app.repository as SqliteCounterRepository).db);

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    controller.dispose();
    super.dispose();
  }

  void changed(String value) {
    debounce?.cancel();
    final token = ++generation;
    setState(() {
      results.clear();
      error = null;
      loading = value.trim().isNotEmpty;
    });
    debounce = Timer(
      const Duration(milliseconds: 300),
      () => search(value.trim(), token),
    );
  }

  Future<void> search(String query, int token) async {
    if (query.isEmpty) return;
    bool current() => mounted && token == generation;
    final found = <Map<String, Object?>>[];
    try {
      final rows = await repository.db.query(
        'notes',
        columns: ['id'],
        where: 'deletedAt IS NULL',
        orderBy: 'isPinned DESC, updatedAt DESC, id',
      );
      for (final row in rows) {
        if (!current()) return;
        final note = await repository.get(row['id'] as String);
        final match = await compute(matchNoteText, {
          'query': query,
          'title': '${note['title'] ?? ''}',
          'body': '${note['body'] ?? ''}',
        });
        if (match != null) {
          found.add({
            'id': row['id'],
            'title': note['title'],
            'source': '笔记',
            ...match,
          });
        }
      }
      for (final article
          in widget.app.appLinks?.publishedNotes ?? <Map<String, dynamic>>[]) {
        if (!current()) return;
        final body = '${article['body'] ?? ''}';
        final title = '${article['title'] ?? ''}';
        final match = await compute(matchNoteText, {
          'query': query,
          'title': title,
          'body': body,
        });
        if (match != null) {
          found.add({
            'id': 'resource-${sha256.convert(utf8.encode(body))}',
            'title': title,
            'body': body,
            'source': '资料',
            ...match,
          });
        }
      }
      if (!current()) return;
      setState(() {
        results.addAll(found);
        loading = false;
      });
    } catch (_) {
      if (current()) {
        setState(() {
          loading = false;
          error = '搜索失败，请重试';
        });
      }
    }
  }

  Future<void> open(Map<String, Object?> result) async {
    if (opening) return;
    opening = true;
    try {
      final stored = result['source'] == '笔记';
      final note = stored
          ? await repository.get(result['id'] as String)
          : result;
      if (note.isEmpty || note['deletedAt'] != null) {
        throw StateError('Unavailable');
      }
      final body = '${note['body'] ?? ''}';
      final match = await compute(matchNoteText, {
        'query': controller.text.trim(),
        'title': '${note['title'] ?? ''}',
        'body': body,
      });
      final prepared = await PreparedNoteReader.load(body);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NoteReaderPage(
            app: widget.app,
            body: body,
            noteId: result['id'] as String,
            scope: widget.app.scopeId,
            title: '${note['title'] ?? ''}',
            storedNote: stored,
            prepared: prepared,
            documentOffset: match?['offset'] as int? ?? 0,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文章暂时无法打开，请重新搜索')));
      }
    } finally {
      opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      title: TextField(
        controller: controller,
        autofocus: true,
        onChanged: changed,
        decoration: const InputDecoration(
          hintText: '搜索笔记与文章',
          border: InputBorder.none,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (value) {
          debounce?.cancel();
          changed(value);
        },
      ),
    ),
    body: Column(
      children: [
        const ListTile(
          dense: true,
          leading: Icon(Icons.info_outline, size: 18),
          title: Text('共享文章搜索尚未接入'),
        ),
      if (widget.app.appLinks?.value['published_notes'] is! List)
        const ListTile(
          dense: true,
          leading: Icon(Icons.cloud_off, size: 18),
          title: Text('资料文章尚未加载，目前仅搜索我的笔记'),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (!loading &&
            error == null &&
            controller.text.trim().isNotEmpty &&
            results.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('笔记和资料中没有找到匹配内容'),
          ),
        Expanded(
          child: ListView.builder(
            key: const PageStorageKey('note-search-results'),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final result = results[index];
              final title = '${result['title'] ?? ''}'.trim();
              return ListTile(
                leading: Text('${result['source']}'),
                title: Text(
                  title.isEmpty ? '${result['snippet']}' : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${result['snippet']}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => open(result),
              );
            },
          ),
        ),
      ],
    ),
  );
}
