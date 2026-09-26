import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/data/remote/resource_transfer_error.dart';

void main() {
  test('HTTP errors preserve actionable categories including Storage 400', () {
    expect(
      resourceHttpFailure('test', 413, 'too large').code,
      'FILE_TOO_LARGE',
    );
    expect(
      resourceHttpFailure(
        'test',
        400,
        'The object exceeded the maximum allowed size',
      ).code,
      'FILE_TOO_LARGE',
    );
    expect(
      resourceHttpFailure('test', 403, 'RLS policy violation').code,
      'UPLOAD_PERMISSION_DENIED',
    );
    expect(
      resourceHttpFailure('test', 415, 'unsupported MIME').code,
      'FILE_TYPE_NOT_ALLOWED',
    );
    expect(
      resourceHttpFailure('test', 503, 'unavailable').code,
      'RESOURCE_SERVER_UNAVAILABLE',
    );
    expect(
      resourceHttpFailure('test', 400, 'Invalid Compact JWS').code,
      'UPLOAD_AUTH_FAILED',
    );
  });
  test('diagnostics retain error but redact URLs and tokens', () {
    final value = resourceDiagnosticBody(
      'Invalid Compact JWS https://storage.test?token=secret Bearer secret eyJhbGc.eyJzdWI.signature',
    );
    expect(value, contains('Invalid Compact JWS'));
    expect(value, isNot(contains('secret')));
    expect(value, isNot(contains('eyJ')));
    expect(resourceDiagnosticBody('x' * 9000).length, 2048);
  });
}
