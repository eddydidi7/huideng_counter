import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'resource_upload_task.dart';

// Keep the server error for diagnosis, but never log signed URLs or credentials.
String resourceDiagnosticBody(Object? body) {
  var text = body is String ? body : jsonEncode(body);
  text = text.replaceAll(RegExp(r'https?://[^\s"<>]+'), '[url]');
  text = text.replaceAll(
    RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
    '[token]',
  );
  text = text.replaceAll(
    RegExp(r'(Bearer\s+)[^\s"<>]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  return text.length > 2048 ? text.substring(0, 2048) : text;
}

DriveFailure resourceHttpFailure(String stage, int status, Object? body) {
  final detail = resourceDiagnosticBody(body);
  debugPrint('[public-resources] stage=$stage HTTP=$status body=$detail');
  final lower = detail.toLowerCase();
  final code = switch (status) {
    401 => 'LOGIN_REQUIRED',
    _
        when lower.contains('invalid compact jws') ||
            lower.contains('invalid jwt') =>
      'UPLOAD_AUTH_FAILED',
    403 => 'UPLOAD_PERMISSION_DENIED',
    413 => 'FILE_TOO_LARGE',
    415 => 'FILE_TYPE_NOT_ALLOWED',
    408 || 504 => 'UPLOAD_TIMEOUT',
    429 => 'RESOURCE_RATE_LIMIT',
    _
        when lower.contains('exceed') &&
            (lower.contains('size') || lower.contains('large')) =>
      'FILE_TOO_LARGE',
    _ when lower.contains('mime') => 'FILE_TYPE_NOT_ALLOWED',
    _
        when lower.contains('row-level security') ||
            lower.contains('policy violation') =>
      'UPLOAD_PERMISSION_DENIED',
    _ when status >= 500 => 'RESOURCE_SERVER_UNAVAILABLE',
    _ => 'RESOURCE_REQUEST_FAILED',
  };
  return DriveFailure(code);
}

Never resourceTransportFailure(String stage, Object error, StackTrace stack) {
  debugPrint(
    '[public-resources] stage=$stage ${error.runtimeType}: ${resourceDiagnosticBody(error.toString())}',
  );
  if (error is TimeoutException) throw const DriveFailure('UPLOAD_TIMEOUT');
  if (error is SocketException || error is http.ClientException) {
    throw const DriveFailure('NETWORK_FAILED');
  }
  Error.throwWithStackTrace(error, stack);
}
