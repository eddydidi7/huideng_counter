import 'dart:convert';
import '../core/app_controller.dart';
import '../data/repositories/notes_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import '../presentation/note_rich_content.dart';

/// Copies content into the active account's private notes; never updates sources.
class ContentTransfer {
  final AppController app;
  ContentTransfer(this.app);
  NotesRepository get notes =>
      NotesRepository((app.repository as SqliteCounterRepository).db);
  Future<Map<String, Object?>> postToNote(Map<String, dynamic> post) =>
      notes.save({
        'title': post['title'] ?? '',
        'body': post['rich_body'] is List
            ? jsonEncode(post['rich_body'])
            : post['body'] ?? '',
        'source_post_id': post['id'],
        'source_meta': jsonEncode({
          'type': 'redbook_post',
          'id': post['id'],
          'author': post['author_name'],
          'attachments': (post['attachments'] as List? ?? [])
              .map(
                (a) => {
                  for (final k in ['id', 'path', 'kind', 'name']) k: a[k],
                },
              )
              .toList(),
        }),
      });
  Future<Map<String, Object?>> messagesToNote(
    String room,
    String title,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> members,
  ) {
    final ordered = [...messages]
      ..sort(
        (a, b) => '${a['created_at']}${a['id']}'.compareTo(
          '${b['created_at']}${b['id']}',
        ),
      );
    final names = {for (final m in members) m['user_id']: m['nickname']};
    final body = ordered
        .map(
          (m) =>
              '${names[m['sender_id']] ?? m['sender_id']} · ${m['created_at']}\n${m['body'] ?? ''}${m['attachment_name'] == null ? '' : '\n附件：${m['attachment_name']}'}',
        )
        .join('\n\n');
    return notes.save({
      'title': title,
      'body': body,
      'source_meta': jsonEncode({
        'type': 'chat',
        'room_id': room,
        'messages': ordered
            .map(
              (m) => {
                'id': m['id'],
                'sender_id': m['sender_id'],
                'created_at': m['created_at'],
                'attachment_path': m['attachment_path'],
                'attachment_name': m['attachment_name'],
              },
            )
            .toList(),
      }),
    });
  }

  String noteText(String body) => NoteRichContent.plainText(body);
}
