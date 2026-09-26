import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class NoteExport {
  static String plain(List<dynamic> ops) => ops
      .map((o) => o['insert'] is String ? o['insert'] as String : '\n[图片]\n')
      .join()
      .trimRight();
  static String markdown(List<dynamic> ops) {
    final out = StringBuffer(), line = StringBuffer();
    for (final op in ops) {
      final a = op['attributes'] as Map? ?? {};
      final insert = op['insert'];
      if (insert is Map) {
        if (insert['image'] is String) {
          line.write('![图片](<${insert['image']}>)');
        }
        continue;
      }
      final parts = (insert as String).split('\n');
      for (var i = 0; i < parts.length; i++) {
        var t = parts[i].replaceAllMapped(
          RegExp(r'[\\`*_\[\]<>]'),
          (m) => '\\${m[0]}',
        );
        if (t.isNotEmpty) {
          if (a['bold'] == true) t = '**$t**';
          if (a['italic'] == true) t = '*$t*';
          if (a['strike'] == true) t = '~~$t~~';
          if (a['link'] is String) t = '[$t](<${a['link']}>)';
          line.write(t);
        }
        if (i < parts.length - 1) {
          final header = a['header'] as int?;
          final prefix = header != null
              ? '${'#' * header.clamp(1, 6)} '
              : a['list'] == 'ordered'
              ? '1. '
              : a['list'] == 'bullet'
              ? '- '
              : a['blockquote'] == true
              ? '> '
              : '';
          out.writeln('$prefix$line');
          line.clear();
        }
      }
    }
    out.write(line);
    return out.toString();
  }

  // Rasterize with Flutter's installed fallback fonts so Chinese/Tibetan text
  // exports offline without downloading fonts. PDF text is not selectable.
  static Future<Uint8List> pdf(List<dynamic> ops) async {
    final doc = pw.Document();
    const width = 515.0, height = 762.0, scale = 2.0;
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder)..scale(scale);
    var y = 0.0;
    Future<void> flush() async {
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        (width * scale).ceil(),
        (height * scale).ceil(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          build: (_) =>
              pw.Image(pw.MemoryImage(bytes), width: width, height: height),
        ),
      );
      image.dispose();
      picture.dispose();
      recorder = ui.PictureRecorder();
      canvas = Canvas(recorder)..scale(scale);
      y = 0;
    }

    Future<void> text(String value) async {
      for (final line in value.split('\n')) {
        final painter = TextPainter(
          text: TextSpan(
            text: line.isEmpty ? ' ' : line,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black,
              height: 1.5,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        final metrics = painter.computeLineMetrics();
        var offset = 0.0;
        for (final metric in metrics) {
          if (y + metric.height > height) await flush();
          canvas.save();
          canvas.clipRect(Rect.fromLTWH(0, y, width, metric.height));
          painter.paint(canvas, Offset(0, y - offset));
          canvas.restore();
          offset += metric.height;
          y += metric.height;
        }
        painter.dispose();
      }
    }

    final buffer = StringBuffer();
    for (final op in ops) {
      if (op['insert'] is String) {
        buffer.write(op['insert']);
        continue;
      }
      if (buffer.isNotEmpty) {
        await text(buffer.toString());
        buffer.clear();
      }
      final source = (op['insert'] as Map)['image'];
      if (source is String && source.startsWith('data:image/')) {
        final codec = await ui.instantiateImageCodec(
          base64Decode(source.split(',').last),
          targetWidth: 1030,
        );
        final image = (await codec.getNextFrame()).image;
        final h = (width * image.height / image.width).clamp(1.0, height);
        if (y + h > height) await flush();
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(0, y, h * image.width / image.height, h),
          Paint(),
        );
        y += h;
        image.dispose();
        codec.dispose();
      } else {
        await text('[图片：$source]');
      }
    }
    if (buffer.isNotEmpty) await text(buffer.toString());
    await flush();
    recorder.endRecording().dispose();
    return doc.save();
  }
}
