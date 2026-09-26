export 'package:huideng_connection/resource_upload_task.dart';
class CloudFile {
  CloudFile(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get owner => data['user_id'] as String;
  String get name => data['file_name'] as String;
  String get key => data['object_key'] as String;
  String get checksum => data['checksum'] as String;
  int get size => (data['file_size'] as num).toInt();
  bool get ready => data['upload_state'] == 'ready';
  bool get deleted => data['deleted_at'] != null;
}

class StorageCredential {
  StorageCredential(Map<String, dynamic> j)
    : provider = j['provider'],
      accessKeyId = j['accessKeyId'],
      accessKeySecret = j['accessKeySecret'],
      securityToken = j['securityToken'],
      bucket = j['bucket'],
      region = j['region'],
      endpoint = j['endpoint'],
      expiresAt = DateTime.parse(j['expiresAt']),
      userPrefix = j['userPrefix'],
      objectKey = j['objectKey'];
  final String provider,
      accessKeyId,
      accessKeySecret,
      securityToken,
      bucket,
      region,
      endpoint,
      userPrefix,
      objectKey;
  final DateTime expiresAt;
  bool get fresh => expiresAt.difference(DateTime.now()).inMinutes >= 5;
  @override
  String toString() => 'StorageCredential($provider, redacted)';
}

class CloudListing {
  CloudListing(Map<String, dynamic> j)
    : files = (j['files'] as List)
          .map((f) => CloudFile(Map<String, dynamic>.from(f)))
          .toList(),
      quota = Map<String, dynamic>.from(j['quota']),
      configured = j['configured'] == true,
      nextOffset = j['nextOffset'] as int?;
  final List<CloudFile> files;
  final Map<String, dynamic> quota;
  final bool configured;
  final int? nextOffset;
}

