import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';

String stamp(Object? value) {
  if (value == null) return '—';
  final d = (value is DateTime ? value : DateTime.parse(value as String))
      .toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

void showFailure(BuildContext context, AppController app, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        app.text(
          '操作未完成，请重试。数量须为有效非负整数。',
          'Could not save. Retry and check that the count is a valid non-negative integer.',
        ),
      ),
    ),
  );
}

class ProjectImage extends StatelessWidget {
  final String? path;
  final double size;
  final double? height;
  final BoxFit fit;
  final double? cornerRadius;
  const ProjectImage({
    super.key,
    this.path,
    this.size = 64,
    this.height,
    this.fit = BoxFit.cover,
    this.cornerRadius,
  });
  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: height ?? size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xffe6d8bd), Color(0xffc4a578)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(
        Icons.spa_outlined,
        size: (height != null && height! < size ? height! : size) * .48,
        color: const Color(0xff765b3c),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius ?? size * .22),
      child: path == null
          ? placeholder
          : Image.file(
              File(path!),
              width: size,
              height: height ?? size,
              fit: fit,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
