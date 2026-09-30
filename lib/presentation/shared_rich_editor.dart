import 'note_typography_page.dart';
import 'windows_display.dart';
import 'dart:convert';
import 'routed_image.dart';
import 'note_rich_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

/// Use the visible text position, not a pixel percentage (images and headings
/// have different heights in the editor and reader).
int visibleNoteOffset(
  GlobalKey<quill.EditorState> editorKey,
  GlobalKey viewportKey,
) {
  final editor = editorKey.currentState?.renderEditor;
  final viewport = viewportKey.currentContext?.findRenderObject();
  if (editor == null || viewport is! RenderBox || !viewport.hasSize) return 0;
  return editor
      .getPositionForOffset(viewport.localToGlobal(const Offset(18, 8)))
      .offset;
}

/// Shared editing surface for private notes and published long-form content.
class SharedRichEditor extends StatelessWidget {
  const SharedRichEditor({
    super.key,
    required this.controller,
    required this.config,
    this.focusNode,
    this.scrollController,
    this.readingScope,
  });
  final quill.QuillController controller;
  final quill.QuillEditorConfig config;
  final FocusNode? focusNode;
  final ScrollController? scrollController;
  final String? readingScope;
  @override
  Widget build(BuildContext context) {
    Widget editor(quill.QuillEditorConfig resolved) => WindowsContentText(
      independentSize: readingScope != null,
      child: quill.QuillEditor.basic(
        controller: controller,
        config: resolved,
        focusNode: focusNode,
        scrollController: scrollController,
      ),
    );
    if (readingScope == null) return editor(config);
    final typography = NoteTypography.forScope(readingScope!);
    return ListenableBuilder(
      listenable: typography,
      builder: (context, _) => editor(
        config.copyWith(
          customStyles: quill.DefaultStyles(
            paragraph: quill.DefaultTextBlockStyle(
              TextStyle(
                fontSize: typography.size,
                height: NoteTypography.textHeight(
                  typography.size,
                  typography.line,
                ),
                color: Theme.of(context).colorScheme.onSurface,
                fontFamily: typography.font == 'source'
                    ? 'SourceHanSans'
                    : null,
              ),
              quill.HorizontalSpacing.zero,
              quill.VerticalSpacing(0, typography.paragraph),
              quill.VerticalSpacing.zero,
              null,
            ),
          ),
        ),
      ),
    );
  }
}

class NoteImageBuilder extends quill.EmbedBuilder {
  @override
  String get key => 'image';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final source = embedContext.node.value.data.toString();
    try {
      if (source.startsWith('data:image/')) {
        return Image.memory(
          base64Decode(source.substring(source.indexOf(',') + 1)),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        );
      }
      if (Uri.tryParse(source)?.scheme == 'https') {
        return RoutedImage(
          source,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        );
      }
    } catch (_) {
      // Preserve the original embed data even if the image cannot be decoded.
    }
    return const Icon(Icons.broken_image_outlined);
  }
}

class RichContentView extends StatefulWidget {
  const RichContentView({super.key, required this.body});
  final String body;
  @override
  State<RichContentView> createState() => _RichContentViewState();
}

class _RichContentViewState extends State<RichContentView> {
  late final controller = quill.QuillController(
    document: NoteRichContent.documentFromBody(widget.body),
    selection: const TextSelection.collapsed(offset: 0),
  )..readOnly = true;
  @override
  void didUpdateWidget(RichContentView old) {
    super.didUpdateWidget(old);
    if (old.body != widget.body) {
      controller.document = NoteRichContent.documentFromBody(widget.body);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SharedRichEditor(
    controller: controller,
    config: quill.QuillEditorConfig(
      scrollable: false,
      showCursor: false,
      padding: EdgeInsets.zero,
      embedBuilders: [NoteImageBuilder()],
    ),
  );
}
