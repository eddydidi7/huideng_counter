import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// Only the offline-pinned signing public key authorizes new API destinations.
/// The project URL/public API key/session namespace never change.
class SignedConnectionConfig {
  final int version;
  final DateTime expiresAt;
  final List<Uri> origins;
  final String payload;
  SignedConnectionConfig(
    this.version,
    this.expiresAt,
    this.origins,
    this.payload,
  );

  static Uri origin(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.host == 'localhost' ||
        !RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(uri.host) ||
        RegExp(r'^\d+(\.\d+){3}$').hasMatch(uri.host)) {
      throw const FormatException('Invalid HTTPS origin');
    }
    return Uri(scheme: 'https', host: uri.host);
  }

  static Future<SignedConnectionConfig> verify(
    String envelope, {
    required String publicKey,
    required String project,
    required DateTime now,
    int minimumVersion = 0,
    String? currentPayload,
    bool allowExpired = false,
  }) async {
    if (envelope.length > 32768) {
      throw const FormatException('Config too large');
    }
    final obj = jsonDecode(envelope) as Map<String, dynamic>;
    final bytes = base64Decode(obj['payload'] as String);
    final key = base64Decode(publicKey);
    final signature = base64Decode(obj['signature'] as String);
    if (key.length != 32 ||
        signature.length != 64 ||
        !await Ed25519().verify(
          bytes,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
          ),
        )) {
      throw const FormatException('Invalid signature');
    }
    final value = utf8.decode(bytes);
    final data = jsonDecode(value) as Map<String, dynamic>;
    final version = data['version'];
    final expiry = DateTime.parse(data['expires_at'] as String).toUtc();
    final issued = DateTime.parse(data['issued_at'] as String).toUtc();
    if (data['schema'] != 1 ||
        data['project'] != project ||
        version is! int ||
        version < 1 ||
        version > 9007199254740991 ||
        version < minimumVersion ||
        (version == minimumVersion &&
            currentPayload != null &&
            value != currentPayload) ||
        (!allowExpired && !expiry.isAfter(now)) ||
        issued.isAfter(now.add(const Duration(minutes: 5))) ||
        !expiry.isAfter(issued) ||
        expiry.difference(issued) > const Duration(days: 180)) {
      throw const FormatException('Invalid version, project or lifetime');
    }
    final raw = data['origins'] as List;
    if (raw.isEmpty || raw.length > 4) {
      throw const FormatException('Invalid origin count');
    }
    final urls = raw.map((x) => origin(x as String)).toList();
    if (urls.toSet().length != urls.length) {
      throw const FormatException('Duplicate origin');
    }
    return SignedConnectionConfig(version, expiry, urls, value);
  }
}
