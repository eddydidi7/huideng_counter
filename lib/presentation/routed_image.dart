import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/cloud_controller.dart';

/// Only project-hosted images use the approved backend routing transport.
class RoutedImage extends StatefulWidget {
  const RoutedImage(
    this.url, {
    super.key,
    this.fit,
    this.height,
    this.width,
    this.errorBuilder,
    this.cacheWidth,
  });
  final String url;
  final BoxFit? fit;
  final double? height, width;
  final ImageErrorWidgetBuilder? errorBuilder;
  final int? cacheWidth;
  @override
  State<RoutedImage> createState() => _RoutedImageState();
}

class _RoutedImageState extends State<RoutedImage> {
  static final _bytes = <String, Uint8List>{};
  static final _requests = <String, Future<Uint8List>>{};
  static int _size = 0;
  Future<Uint8List> cachedLoad(String url) async {
    final cached = _bytes[url];
    if (cached != null) return cached;
    final existing = _requests[url];
    if (existing != null) return existing;
    final task = load(url);
    _requests[url] = task;
    try {
      final value = await task;
      while (_bytes.isNotEmpty && _size + value.length > 32 * 1024 * 1024) {
        final key = _bytes.keys.first;
        _size -= _bytes.remove(key)!.length;
      }
      _bytes[url] = value;
      _size += value.length;
      return value;
    } finally {
      _requests.remove(url);
    }
  }

  Future<Uint8List>? pending;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    CloudController.connection.addListener(changed);
    reload();
  }

  void changed() {
    if (mounted && !loading) setState(reload);
  }

  @override
  void didUpdateWidget(covariant RoutedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) reload();
  }

  void reload() {
    if (!CloudController.connection.owns(Uri.parse(widget.url))) {
      pending = null;
      return;
    }
    pending = cachedLoad(widget.url);
  }

  Future<Uint8List> load(String url) async {
    loading = true;
    final client = CloudController.networkClient();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) throw StateError('Image unavailable');
      final builder = BytesBuilder();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (builder.length + chunk.length > 24 * 1024 * 1024) {
          throw StateError('Image too large');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
      loading = false;
    }
  }

  @override
  void dispose() {
    CloudController.connection.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (pending == null) {
      return Image.network(
        widget.url,
        cacheWidth: widget.cacheWidth,
        fit: widget.fit,
        height: widget.height,
        width: widget.width,
        errorBuilder: widget.errorBuilder,
      );
    }
    return FutureBuilder<Uint8List>(
      future: pending,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.errorBuilder?.call(
                context,
                snapshot.error!,
                snapshot.stackTrace,
              ) ??
              const Icon(Icons.broken_image_outlined);
        }
        if (!snapshot.hasData) {
          return SizedBox(height: widget.height, width: widget.width);
        }
        return Image.memory(
          snapshot.data!,
          cacheWidth: widget.cacheWidth,
          fit: widget.fit,
          height: widget.height,
          width: widget.width,
          errorBuilder: widget.errorBuilder,
        );
      },
    );
  }
}
