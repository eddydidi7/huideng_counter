import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Local diagnostics only. Never record tokens, headers, email or note content.
class SyncDiagnostics {
  static File? file;
  static Future<void> _writes = Future.value();
  static final httpStatuses = <String, int>{};
  static void record(String action, Map<String, Object?> fields) {
    final line = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'action': action,
      ...fields,
    });
    debugPrint('HUIDENG_SYNC $line');
    final output = file;
    if (output != null) {
      _writes = _writes
          .then(
            (_) => output
                .writeAsString('$line\n', mode: FileMode.append)
                .then((_) {}),
          )
          .catchError((Object error) {
            debugPrint(
              'HUIDENG_SYNC diagnostic_write_failed ${error.runtimeType}',
            );
          });
    }
  }

  static String safeMessage(String message) {
    final cleaned = message
        .replaceAll(
          RegExp(r'Bearer\s+\S+', caseSensitive: false),
          'Bearer [redacted]',
        )
        .replaceAll(RegExp(r'eyJ[A-Za-z0-9_.-]+'), '[redacted token]')
        .replaceAll(RegExp(r'\([^)]*\)'), '(details omitted)');
    return cleaned.substring(0, cleaned.length.clamp(0, 500));
  }
}

class SyncHttpClient extends http.BaseClient {
  SyncHttpClient({http.Client? inner}) : _inner = inner ?? http.Client();
  final http.Client _inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final monitored =
        path.endsWith('/sync_note_v1') ||
        path.endsWith('/pull_notes_v1') ||
        path.startsWith('/auth/v1/');
    if (monitored) SyncDiagnostics.httpStatuses.remove(path);
    try {
      final result = await _inner.send(request);
      if (monitored) {
        SyncDiagnostics.httpStatuses[path] = result.statusCode;
        SyncDiagnostics.record('http_result', {
          'path': path,
          'http_status': result.statusCode,
        });
      }
      return result;
    } catch (e) {
      if (monitored) {
        SyncDiagnostics.record('http_transport_failure', {
          'path': path,
          'error_type': e.runtimeType.toString(),
        });
      }
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

class NoteSyncFailure implements Exception {
  final String category;
  final String? code, message;
  final int? httpStatus;
  const NoteSyncFailure(
    this.category, {
    this.code,
    this.message,
    this.httpStatus,
  });
}
