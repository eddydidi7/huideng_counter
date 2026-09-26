import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../domain/cloud_file.dart';

/// Signs a read of one generated object using short-lived read-only STS.
Map<String, String> ossReadHeaders(StorageCredential c, {DateTime? now}) {
  final timestamp = (now ?? DateTime.now())
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]|\.\d+'), '');
  final date = timestamp.substring(0, 8);
  final region = c.region.replaceFirst(RegExp(r'^oss-'), '');
  final scope = '$date/$region/oss/aliyun_v4_request';
  final headers = <String, String>{
    'x-oss-content-sha256': 'UNSIGNED-PAYLOAD',
    'x-oss-date': timestamp,
    'x-oss-security-token': c.securityToken,
  };
  final canonicalHeaders = headers.entries
      .map((e) => '${e.key}:${e.value.trim()}\n')
      .join();
  final path = '/${c.bucket}/${c.objectKey}'
      .split('/')
      .map(Uri.encodeComponent)
      .join('/');
  final canonical = 'GET\n$path\n\n$canonicalHeaders\n\nUNSIGNED-PAYLOAD';
  final toSign =
      'OSS4-HMAC-SHA256\n$timestamp\n$scope\n${sha256.convert(utf8.encode(canonical))}';
  List<int> key = utf8.encode('aliyun_v4${c.accessKeySecret}');
  for (final part in [date, region, 'oss', 'aliyun_v4_request']) {
    key = Hmac(sha256, key).convert(utf8.encode(part)).bytes;
  }
  final signature = Hmac(sha256, key).convert(utf8.encode(toSign));
  headers['Authorization'] =
      'OSS4-HMAC-SHA256 Credential=${c.accessKeyId}/$scope,Signature=$signature';
  return headers;
}
