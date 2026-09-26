import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../core/app_controller.dart';
import '../data/local/chat_store.dart';
import '../domain/chat_emojis.dart';
import '../services/chat_sticker_store.dart';

class ChatEmojiChoice {
  const ChatEmojiChoice({this.emoji, this.path});
  final String? emoji, path;
}

class ChatEmojiPanel extends StatefulWidget {
  const ChatEmojiPanel({super.key, required this.app, required this.store});
  final AppController app;
  final ChatStore store;
  @override
  State<ChatEmojiPanel> createState() => _ChatEmojiPanelState();
}

class _ChatEmojiPanelState extends State<ChatEmojiPanel> {
  late final favorites = ChatStickerStore(widget.store);
  List<Map<String, dynamic>> stickers = [];
  List<String> recent = [];
  bool busy = false;
  String? error;
  int category = 0;
  String tr(String zh, String en) => widget.app.text(zh, en);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final items = await favorites.list();
      final used = await widget.store.read('recent_emojis_v1');
      if (mounted) {
        setState(() {
          stickers = items;
          recent = used
              .map((m) => m['emoji'] as String)
              .where(chatEmojiSet.contains)
              .toList();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            '无法读取表情，请重新打开',
            'Could not load emoji. Please reopen.',
          ),
        );
      }
    }
  }

  Future<void> choose(String value) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.store.write(
        'recent_emojis_v1',
        [
          value,
          ...recent.where((s) => s != value),
        ].take(24).map((s) => {'emoji': s}).toList(),
      );
    } catch (_) {
      // Emoji insertion remains available if the recent-use cache cannot be saved.
      debugPrint('chat emoji: recent-use cache write failed');
    }
    if (mounted) Navigator.pop(context, ChatEmojiChoice(emoji: value));
  }

  Future<void> add() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final files = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
        allowMultiple: true,
      );
      if (files != null) {
        for (final picked in files.files) {
          if (picked.path == null || picked.size > 10 * 1024 * 1024) {
            throw const FormatException();
          }
          await favorites.add(await File(picked.path!).readAsBytes());
        }
        await load();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            '部分图片未能添加，请选择10MB以内PNG、JPG、GIF或WebP图片',
            'Some images could not be added. Use PNG, JPG, GIF or WebP up to 10 MB.',
          ),
        );
      }
      await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sendSticker(Map<String, dynamic> item) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final path = await favorites.localPath(item);
      if (mounted) Navigator.pop(context, ChatEmojiChoice(path: path));
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            '图片无法读取，请重新添加',
            'Image unavailable. Please add it again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(Map<String, dynamic> item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('移除收藏表情？', 'Remove favorite sticker?')),
        content: Text(
          tr('不会删除聊天记录或原图片。', 'Messages and original images are kept.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('移除', 'Remove')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await favorites.remove(item['id'] as String);
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error = tr('移除失败，请重试', 'Could not remove. Retry.'));
      }
    }
  }

  Widget emojis(List<String> values) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 48,
      mainAxisExtent: 48,
    ),
    itemCount: values.length,
    itemBuilder: (_, i) => InkWell(
      onTap: busy ? null : () => choose(values[i]),
      child: Center(
        child: Text(values[i], style: const TextStyle(fontSize: 28)),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .58,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  text: tr('常用表情', 'Emoji'),
                ),
                Tab(
                  icon: const Icon(Icons.favorite_border),
                  text: tr('收藏表情', 'Favorites'),
                ),
              ],
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    padding: const EdgeInsets.all(10),
                    children: [
                      if (recent.isNotEmpty) ...[
                        Text(tr('最近使用', 'Recent')),
                        emojis(recent),
                      ],
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < chatEmojiGroups.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(
                                    tr(
                                      chatEmojiGroups.keys.elementAt(i),
                                      chatEmojiGroupEnglish[i],
                                    ),
                                  ),
                                  selected: category == i,
                                  onSelected: (_) =>
                                      setState(() => category = i),
                                ),
                              ),
                          ],
                        ),
                      ),
                      emojis(
                        chatEmojiGroups.values.elementAt(category).split(' '),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          tr(
                            '点选发送 · 长按移除 · 收藏保存在本机',
                            'Tap to send · Hold to remove · Saved on this device',
                          ),
                        ),
                      ),
                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.all(10),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 90,
                                mainAxisExtent: 88,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: stickers.length + 1,
                          itemBuilder: (_, i) {
                            if (i == 0) {
                              return IconButton(
                                tooltip: tr('添加表情图片', 'Add stickers'),
                                onPressed: busy ? null : add,
                                icon: const Icon(Icons.add, size: 36),
                              );
                            }
                            final item = stickers[i - 1];
                            return InkWell(
                              onTap: busy ? null : () => sendSticker(item),
                              onLongPress: busy ? null : () => remove(item),
                              child: item['asset'] != null
                                  ? Image.asset(
                                      item['asset'] as String,
                                      fit: BoxFit.contain,
                                      cacheWidth: 180,
                                    )
                                  : Image.file(
                                      File(item['path'] as String),
                                      fit: BoxFit.contain,
                                      cacheWidth: 180,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
