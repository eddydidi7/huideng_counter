import 'package:flutter/material.dart';
import '../core/app_controller.dart';

class PublishedNotesPage extends StatelessWidget {
  final AppController app;
  final bool embedded;
  final String search;
  const PublishedNotesPage({
    super.key,
    required this.app,
    this.embedded = false,
    this.search = '',
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final notes = (app.appLinks?.publishedNotes ?? [])
          .where(
            (n) => (n['body'] as String? ?? '').toLowerCase().contains(
              search.toLowerCase(),
            ),
          )
          .toList();
      final content = notes.isEmpty
          ? Center(
              child: Text(
                app.text(
                  '暂无资料，联网后可刷新',
                  'No shared articles. Connect and refresh.',
                ),
              ),
            )
          : ListView.separated(
              itemCount: notes.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, index) {
                final note = notes[index];
                final body = note['body'] as String? ?? '';
                return ListTile(
                  title: Text(
                    body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    DateTime.tryParse(
                          note['updated_at'] as String? ?? '',
                        )?.toLocal().toString().split('.').first ??
                        '',
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(
                          title: Text(app.text('资料', 'Resources')),
                        ),
                        body: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(body),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
      return Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: app.text('刷新', 'Refresh'),
              onPressed: () => app.appLinks?.refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ),
          Expanded(child: content),
        ],
      );
    },
  );
}
