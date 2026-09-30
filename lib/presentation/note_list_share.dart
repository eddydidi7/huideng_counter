import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/app_controller.dart';
import '../services/note_export.dart';
import 'note_actions_menu.dart';
import 'note_rich_content.dart';
import 'note_share_actions.dart';

Future<void> shareNoteFromList(
  BuildContext context,
  AppController app,
  Map<String, Object?> note,
) async {
  final action = await showNoteActionMenu(context, const [
    (
      action: 'redbook',
      icon: Icons.article_outlined,
      label: '分享到红书',
      submenu: false,
    ),
    (
      action: 'chat',
      icon: Icons.chat_bubble_outline,
      label: '分享到聊天',
      submenu: false,
    ),
    (action: 'get', icon: Icons.link, label: '复制已有文章链接', submenu: false),
    (action: 'copy', icon: Icons.copy_outlined, label: '复制文字', submenu: true),
    (action: 'system', icon: Icons.ios_share, label: '系统分享', submenu: false),
    (
      action: 'export',
      icon: Icons.file_download_outlined,
      label: '导出',
      submenu: true,
    ),
  ]);
  if (action == null || !context.mounted) return;
  final body = note['body'] as String? ?? '';
  final title = note['title'] as String? ?? '';
  try {
    if (['redbook', 'chat', 'get'].contains(action)) {
      await shareReadingNote(
        context,
        app,
        action,
        id: note['id'] as String,
        title: title,
        body: body,
      );
      return;
    }
    if (action == 'copy') {
      final part = await showNoteActionMenu(context, const [
        (
          action: 'body',
          icon: Icons.text_snippet_outlined,
          label: '复制正文',
          submenu: false,
        ),
        (
          action: 'all',
          icon: Icons.copy_all_outlined,
          label: '复制标题 + 正文',
          submenu: false,
        ),
      ]);
      if (part == null || !context.mounted) return;
      final text = NoteRichContent.plainText(body);
      await Clipboard.setData(
        ClipboardData(
          text: part == 'all' && title.trim().isNotEmpty
              ? '$title\n\n$text'
              : text,
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文字已复制')));
      }
      return;
    }
    if (action == 'system') {
      final text = NoteRichContent.plainText(body);
      if (text.length <= 20000) {
        try {
          await const MethodChannel('org.huideng.counter/notes').invokeMethod(
            'shareText',
            title.trim().isEmpty ? text : '$title\n\n$text',
          );
          return;
        } on MissingPluginException {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('当前平台尚无系统分享接口，可以导出文件后分享。')),
            );
          }
        }
      } else if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正文较长，请导出文件后分享。')));
      }
    }
    if (!context.mounted) return;
    final format = await showNoteActionMenu(context, const [
      (
        action: 'txt',
        icon: Icons.text_snippet_outlined,
        label: 'TXT',
        submenu: false,
      ),
      (
        action: 'md',
        icon: Icons.description_outlined,
        label: 'Markdown',
        submenu: false,
      ),
      (
        action: 'pdf',
        icon: Icons.picture_as_pdf_outlined,
        label: 'PDF',
        submenu: false,
      ),
    ]);
    if (format == null) return;
    final doc = NoteRichContent.documentFromBody(body);
    final ops = doc.toDelta().toJson();
    doc.close();
    final bytes = format == 'pdf'
        ? await NoteExport.pdf(ops)
        : Uint8List.fromList(
            utf8.encode(
              format == 'md' ? NoteExport.markdown(ops) : NoteExport.plain(ops),
            ),
          );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出笔记',
      fileName: 'note_${note['id']}.$format',
      type: FileType.custom,
      allowedExtensions: [format],
      bytes: bytes,
    );
    if (path == null) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('笔记已导出')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作未完成，请重试。私人笔记未更改。')));
    }
  }
}
