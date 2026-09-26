import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'resource_upload_task.dart';
import 'resource_transfer_error.dart';

/// TUS uploads use bounded 6 MiB buffers and persist the upload URL, not a token.
Future<void> uploadResourceResumable({
  required http.Client client,
  required File source,
  required DriveUpload task,
  required String owner,
  required Map<String, dynamic> plan,
  required void Function() guard,
  required void Function(double) progress,
}) async {
  final suppliedEndpoint = Uri.parse(plan['url'] as String);
  // Older deployed functions return the ordinary JWT route. Signed upload
  // tokens must use Supabase's /sign route, without relaxing host validation.
  final endpoint = suppliedEndpoint.path == '/storage/v1/upload/resumable'
      ? suppliedEndpoint.replace(path: '/storage/v1/upload/resumable/sign')
      : suppliedEndpoint;
  if (endpoint.scheme != 'https' ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment ||
      endpoint.path != '/storage/v1/upload/resumable/sign' ||
      plan['bucket'] != 'public-resources' ||
      plan['chunk_size'] != 6291456 ||
      plan['token'] is! String ||
      (plan['token'] as String).isEmpty) {
    throw const DriveFailure('INVALID_TRANSFER');
  }
  final headers = {
    'Tus-Resumable': '1.0.0',
    'x-signature': plan['token'] as String,
  };
  final prefs = await SharedPreferences.getInstance();
  final key = 'resource_tus_${owner}_${task.id}_${task.checksum}';
  Uri validLocation(String raw) {
    final uri = endpoint.resolve(raw);
    if (uri.origin != endpoint.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('${endpoint.path}/')) {
      throw const DriveFailure('INVALID_TRANSFER');
    }
    return uri;
  }

  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String> extra = const {},
    List<int>? bytes,
  }) async {
    guard();
    final req = http.Request(method, uri)..followRedirects = false;
    req.headers.addAll({...headers, ...extra});
    if (bytes != null) req.bodyBytes = bytes;
    try {
      final response = await client
          .send(req)
          .timeout(const Duration(minutes: 2));
      final result = await http.Response.fromStream(
        response,
      ).timeout(const Duration(seconds: 30));
      guard();
      return result;
    } catch (e, stack) {
      resourceTransportFailure('tus.$method', e, stack);
    }
  }

  int offsetOf(http.Response r) {
    final offset = int.tryParse(r.headers['upload-offset'] ?? '');
    if (offset == null || offset < 0 || offset > task.size) {
      throw const DriveFailure('INVALID_RESPONSE');
    }
    return offset;
  }

  Uri? location;
  int offset = 0;
  final previous = prefs.getString(key);
  if (previous != null) {
    location = validLocation(previous);
    final head = await send('HEAD', location);
    if (head.statusCode == 200 || head.statusCode == 204) {
      offset = offsetOf(head);
    } else if (head.statusCode == 404 || head.statusCode == 410) {
      location = null;
    } else {
      throw resourceHttpFailure('tus.HEAD', head.statusCode, head.body);
    }
  }
  if (location == null) {
    final metadata =
        {
              'bucketName': 'public-resources',
              'objectName': plan['object_name'] as String,
              'contentType': plan['content_type'] as String,
              'cacheControl': '0',
            }.entries
            .map((e) => '${e.key} ${base64Encode(utf8.encode(e.value))}')
            .join(',');
    final created = await send(
      'POST',
      endpoint,
      extra: {'Upload-Length': '${task.size}', 'Upload-Metadata': metadata},
    );
    // A prior transfer may have finished just before the connection was lost.
    // Only the server's independent size/hash verification can publish it.
    if (created.statusCode == 409) return;
    if (created.statusCode != 201 || created.headers['location'] == null) {
      throw resourceHttpFailure('tus.POST', created.statusCode, created.body);
    }
    location = validLocation(created.headers['location']!);
    if (!await prefs.setString(key, location.toString())) {
      throw const DriveFailure('QUEUE_SAVE_FAILED');
    }
  }
  final reader = await source.open();
  try {
    var failures = 0;
    while (offset < task.size) {
      guard();
      await reader.setPosition(offset);
      final bytes = await reader.read(min(6291456, task.size - offset));
      if (bytes.isEmpty) throw const DriveFailure('LOCAL_FILE_CHANGED');
      try {
        final result = await send(
          'PATCH',
          location,
          extra: {
            'Upload-Offset': '$offset',
            'Content-Type': 'application/offset+octet-stream',
          },
          bytes: bytes,
        );
        if (result.statusCode != 204) {
          throw resourceHttpFailure(
            'tus.PATCH',
            result.statusCode,
            result.body,
          );
        }
        final next = offsetOf(result);
        if (next != offset + bytes.length) {
          throw const DriveFailure('INVALID_RESPONSE');
        }
        offset = next;
        failures = 0;
      } catch (error) {
        guard();
        if (error is DriveFailure &&
            const {
              'LOGIN_REQUIRED',
              'UPLOAD_AUTH_FAILED',
              'UPLOAD_PERMISSION_DENIED',
              'FILE_TOO_LARGE',
              'FILE_TYPE_NOT_ALLOWED',
            }.contains(error.code)) {
          rethrow;
        }
        if (++failures > 3) rethrow;
        // The last PATCH might have committed despite a lost response.
        final head = await send('HEAD', location);
        if (head.statusCode != 200 && head.statusCode != 204) rethrow;
        offset = offsetOf(head);
      }
      progress(offset / task.size);
    }
  } finally {
    await reader.close();
  }
  // Keep the URL until metadata publication succeeds, so retries can HEAD it.
}
