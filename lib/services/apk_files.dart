import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const apkMime = 'application/vnd.android.package-archive';
const maxApkBytes = 500 * 1024 * 1024;
bool isApk(String name) => name.toLowerCase().endsWith('.apk');
String safeApkName(String name) {
  final clean = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
  return isApk(clean) ? clean : '$clean.apk';
}

/// Part files never acquire an installable name until length/hash checks pass.
class ApkFiles {
  static const channel = MethodChannel('org.huideng.counter/apk');
  static Future<File> target(String owner, String id, String name) async {
    final root = await getApplicationSupportDirectory();
    final account = sha256.convert(utf8.encode(owner));
    final key = sha256.convert(utf8.encode(id));
    final dir = await Directory(
      '${root.path}/apk_share/$account/$key',
    ).create(recursive: true);
    return File('${dir.path}/${safeApkName(name)}');
  }

  static Future<bool> valid(File file, int size, [String? checksum]) async {
    if (size < 1 ||
        size > maxApkBytes ||
        !await file.exists() ||
        await file.length() != size) {
      return false;
    }
    if (checksum != null &&
        checksum.isNotEmpty &&
        (await sha256.bind(file.openRead()).first).toString() != checksum) {
      return false;
    }
    return true;
  }

  static Future<String> stage(
    String owner,
    String id,
    String name,
    String source,
  ) async {
    final file = await target(owner, id, name);
    if (File(source).absolute.path != file.absolute.path) {
      final part = await File(source).copy('${file.path}.part');
      await part.rename(file.path);
    }
    return file.path;
  }

  static Future<String> download({
    required String owner,
    required String id,
    required String name,
    required int size,
    required Future<String> Function() url,
    required void Function() guard,
    required void Function(double) progress,
    String? checksum,
    http.Client? transport,
  }) async {
    guard();
    final file = await target(owner, id, name);
    if (await valid(file, size, checksum)) {
      guard();
      progress(1);
      return file.path;
    }
    if (size < 1 || size > maxApkBytes) throw StateError('安装包大小无效，最大 500 MB');
    final uri = Uri.parse(await url());
    if (uri.scheme != 'https') throw StateError('下载地址必须使用 HTTPS');
    guard();
    final client = transport ?? http.Client();
    try {
      final part = File('${file.path}.part');
      var offset = await part.exists() ? await part.length() : 0;
      if (offset >= size) offset = 0;
      // Only resume an immutable, checksum-addressed download.
      if (checksum == null || checksum.isEmpty) offset = 0;
      var destination = uri;
      late http.StreamedResponse response;
      for (var redirects = 0; ; redirects++) {
        if (destination.scheme != 'https' || destination.userInfo.isNotEmpty) {
          throw StateError('下载地址必须使用 HTTPS');
        }
        final request = http.Request('GET', destination)..followRedirects = false;
        if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
        response = await client.send(request).timeout(const Duration(seconds: 45));
        if (![301,302,303,307,308].contains(response.statusCode)) break;
        await response.stream.listen((_) {}).cancel();
        final location = response.headers['location'];
        if (redirects >= 5 || location == null) throw StateError('下载地址重定向异常');
        destination = destination.resolve(location);
      }
      if (response.statusCode == 206) {
        final range = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(response.headers['content-range'] ?? '');
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[3]!) != size) {
          throw StateError('服务器续传响应无效，请重试');
        }
      } else if (response.statusCode == 200) {
        offset = 0;
      } else {
        throw StateError('下载失败（HTTP ${response.statusCode}），请重试');
      }
      final sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var count = offset, flushed = offset;
      try {
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 45),
        )) {
          guard();
          count += bytes.length;
          if (count > size) throw StateError('文件大小不匹配');
          sink.add(bytes);
          if (count - flushed >= 1048576) {
            await sink.flush();
            flushed = count;
          }
          progress(count / size);
        }
      } finally {
        await sink.close();
      }
      if (!await valid(part, size, checksum)) {
        throw StateError('下载不完整或校验失败，请重试');
      }
      guard();
      await part.rename(file.path);
      await File('${file.path}.json').writeAsString(
        jsonEncode({
          'fileId': id,
          'fileName': name,
          'fileSize': size,
          'mimeType': apkMime,
          'localPath': file.path,
          'downloadStatus': 'complete',
          'sha256': (await sha256.bind(file.openRead()).first).toString(),
        }),
        flush: true,
      );
      return file.path;
    } finally {
      if (transport == null) client.close();
    }
  }
}
