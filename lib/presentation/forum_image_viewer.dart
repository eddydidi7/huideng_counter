import 'package:flutter/material.dart';
import 'routed_image.dart';

Future<void> openForumImages(
  BuildContext context,
  List<String> images,
  int index,
) => Navigator.push(
  context,
  PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (_, _, _) =>
        ForumImageViewer(images: images, initialIndex: index),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

/// Full-screen browser: swipe between images, pinch or double-tap to zoom,
/// "2 / 6" counter, tap (when not zoomed) or Back to close.
class ForumImageViewer extends StatefulWidget {
  const ForumImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });
  final List<String> images;
  final int initialIndex;
  @override
  State<ForumImageViewer> createState() => _ForumImageViewerState();
}

class _ForumImageViewerState extends State<ForumImageViewer> {
  late final pager = PageController(initialPage: widget.initialIndex);
  late int index = widget.initialIndex.clamp(0, widget.images.length - 1);
  final zoom = <int, TransformationController>{};
  bool zoomed = false;
  Offset? doubleTapAt;

  TransformationController controller(int i) =>
      zoom.putIfAbsent(i, TransformationController.new);

  @override
  void dispose() {
    pager.dispose();
    for (final c in zoom.values) {
      c.dispose();
    }
    super.dispose();
  }

  void toggleZoom(int i) {
    final c = controller(i);
    if (c.value.getMaxScaleOnAxis() > 1.01) {
      c.value = Matrix4.identity();
      setState(() => zoomed = false);
      return;
    }
    final at = doubleTapAt ?? Offset.zero;
    const scale = 2.5;
    c.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    setState(() => zoomed = true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: [
        PageView.builder(
          key: const ValueKey('forum-image-viewer-pages'),
          controller: pager,
          // Swiping between images is disabled while zoomed so panning works.
          physics: zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.images.length,
          onPageChanged: (i) {
            controller(index).value = Matrix4.identity();
            setState(() {
              index = i;
              zoomed = false;
            });
          },
          itemBuilder: (_, i) => GestureDetector(
            onTap: zoomed ? null : () => Navigator.maybePop(context),
            onDoubleTapDown: (d) => doubleTapAt = d.localPosition,
            onDoubleTap: () => toggleZoom(i),
            child: InteractiveViewer(
              transformationController: controller(i),
              minScale: 1,
              maxScale: 5,
              onInteractionEnd: (_) => setState(
                () => zoomed = controller(i).value.getMaxScaleOnAxis() > 1.01,
              ),
              child: SizedBox.expand(
                child: RoutedImage(
                  widget.images[i],
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Row(
            children: [
              IconButton(
                tooltip: '关闭',
                color: Colors.white,
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.close),
              ),
              const Spacer(),
              if (widget.images.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    '${index + 1}/${widget.images.length}',
                    key: const ValueKey('forum-image-viewer-counter'),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
