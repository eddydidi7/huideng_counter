import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A plain HTTPS download to a specific [targetPath], with an optional
/// SHA-256 check. Unlike ApkFiles.download (lib/services/apk_files.dart),
/// this never forces a .apk extension and has no APK-specific size cap, so
/// it fits both admin-broadcast files and the Windows update installer.
/// Reuses an already-complete, already-verified local copy when present.
Future<String> downloadFile({
  required String url,
  required String targetPath,
  required int size,
  String? sha256Hex,
  int maxBytes = 5368709120,
  void Function(double)? onProgress,
}) async {
  if (size < 1 || size > maxBytes) throw StateError('文件大小无效');
  final file = File(targetPath);
  await file.parent.create(recursive: true);
  if (await file.exists() && await file.length() == size) {
    if (sha256Hex == null || sha256Hex.isEmpty || (await sha256.bind(file.openRead()).first).toString() == sha256Hex) {
      onProgress?.call(1);
      return file.path;
    }
  }
  final uri = Uri.parse(url);
  if (uri.scheme != 'https') throw StateError('下载地址必须使用 HTTPS');
  final client = http.Client();
  try {
    final response = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) throw StateError('下载失败（HTTP ${response.statusCode}），请重试');
    final part = File('${file.path}.part');
    final sink = part.openWrite();
    var count = 0;
    try {
      await for (final bytes in response.stream.timeout(const Duration(seconds: 45))) {
        count += bytes.length;
        if (count > size) throw StateError('文件大小不匹配');
        sink.add(bytes);
        onProgress?.call(count / size);
      }
    } finally {
      await sink.close();
    }
    if (count != size) throw StateError('下载不完整，请重试');
    if (sha256Hex != null && sha256Hex.isNotEmpty) {
      final digest = (await sha256.bind(part.openRead()).first).toString();
      if (digest != sha256Hex) throw StateError('文件校验失败，请重试');
    }
    await part.rename(file.path);
    return file.path;
  } finally {
    client.close();
  }
}
