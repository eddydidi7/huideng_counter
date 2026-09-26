import 'routed_image.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/app_controller.dart';
import '../data/repositories/chat_repository.dart';

Future<String> saveChatAttachment(
  ChatRepository repo,
  Map<String, dynamic> message,
) async {
  repo.remote.checkUser();
  final data = await repo.remote.client.storage
      .from('chat-files')
      .download(message['attachment_path'] as String);
  repo.remote.checkUser();
  final root = await getApplicationDocumentsDirectory();
  final folder = Directory(
    p.join(
      root.path,
      'chat_attachments',
      repo.remote.userId,
      message['id'] as String,
    ),
  );
  await folder.create(recursive: true);
  final name = (message['attachment_name'] as String? ?? 'file').replaceAll(
    RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
    '_',
  );
  final file = File(p.join(folder.path, 'saved_$name'));
  await file.writeAsBytes(data, flush: true);
  return file.path;
}

class ChatGalleryPage extends StatefulWidget {
  final AppController app;
  final ChatRepository repository;
  final List<Map<String, dynamic>> images;
  final int initial;
  const ChatGalleryPage({
    super.key,
    required this.app,
    required this.repository,
    required this.images,
    required this.initial,
  });
  @override
  State<ChatGalleryPage> createState() => _ChatGalleryPageState();
}

class _ChatGalleryPageState extends State<ChatGalleryPage> {
  late int index;
  late PageController controller;
  final urls = <String, Future<String>>{};
  bool saving = false;
  @override
  void initState() {
    super.initState();
    index = widget.initial;
    controller = PageController(initialPage: index);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${index + 1} / ${widget.images.length}'),
      actions: [
        IconButton(
          tooltip: widget.app.text('保存到本机', 'Save to device'),
          onPressed: saving
              ? null
              : () async {
                  setState(() => saving = true);
                  try {
                    final path = await saveChatAttachment(
                      widget.repository,
                      widget.images[index],
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            widget.app.text('已保存到本机', 'Saved on this device'),
                          ),
                          action: SnackBarAction(
                            label: widget.app.text('打开', 'Open'),
                            onPressed: () => OpenFilex.open(path),
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            widget.app.text(
                              '保存失败，请检查网络和空间。',
                              'Could not save. Check connection and space.',
                            ),
                          ),
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => saving = false);
                  }
                },
          icon: const Icon(Icons.download_outlined),
        ),
      ],
    ),
    body: PageView.builder(
      controller: controller,
      itemCount: widget.images.length,
      onPageChanged: (i) => setState(() => index = i),
      itemBuilder: (context, i) {
        final path = widget.images[i]['attachment_path'] as String;
        return FutureBuilder<String>(
          future: urls.putIfAbsent(
            path,
            () => widget.repository.remote.client.storage
                .from('chat-files')
                .createSignedUrl(path, 300),
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: TextButton(
                  onPressed: () => setState(() => urls.remove(path)),
                  child: Text(widget.app.text('加载失败，点击重试', 'Tap to retry')),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: RoutedImage(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => TextButton(
                    onPressed: () => setState(() => urls.remove(path)),
                    child: Text(widget.app.text('点击重试', 'Retry')),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
