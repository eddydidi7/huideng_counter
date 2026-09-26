import 'dart:io';
import 'package:flutter/material.dart';
import '../data/remote/public_resource_api.dart';
import '../domain/public_resource.dart';

bool resourceIsImage(String name) => RegExp(
  r'\.(jpe?g|png|webp|gif|avif)$',
  caseSensitive: false,
).hasMatch(name);

/// Instantiated lazily by the parent's ListView, not while constructing its children.
class ResourceImagePreview extends StatefulWidget {
  const ResourceImagePreview({
    super.key,
    required this.api,
    required this.file,
    required this.onDownload,
    this.onShare,
  });
  final ResourcePreviewApi api;
  final PublicResource file;
  final VoidCallback onDownload;
  final VoidCallback? onShare;
  @override
  State<ResourceImagePreview> createState() => _ResourceImagePreviewState();
}

class _ResourceImagePreviewState extends State<ResourceImagePreview> {
  late Future<File> image;
  @override
  void initState() {
    super.initState();
    image = widget.api.preview(widget.file);
  }

  @override
  void didUpdateWidget(ResourceImagePreview old) {
    super.didUpdateWidget(old);
    if (old.file.checksum != widget.file.checksum ||
        old.file.id != widget.file.id ||
        old.api != widget.api) {
      image = widget.api.preview(widget.file);
    }
  }

  Widget picture(Future<File> source) => FutureBuilder<File>(
    future: source,
    builder: (context, snapshot) => snapshot.hasData
        ? Image.file(
            snapshot.data!,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : snapshot.hasError
        ? const Center(child: Text('预览暂不可用'))
        : const Center(child: CircularProgressIndicator()),
  );
  void open() {
    final large = widget.api.preview(widget.file, large: true);
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(widget.file.name),
            actions: [
              IconButton(
                tooltip: '下载',
                onPressed: widget.onDownload,
                icon: const Icon(Icons.download),
              ),
              if (widget.onShare != null)
                IconButton(
                  tooltip: '分享',
                  onPressed: widget.onShare,
                  icon: const Icon(Icons.share),
                ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(maxScale: 5, child: picture(large)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: open,
    child: Semantics(
      label: '预览 ${widget.file.name}',
      button: true,
      child: SizedBox(
        height: 180,
        width: double.infinity,
        child: picture(image),
      ),
    ),
  );
}
