import 'cloud_file.dart';

// Contract v1: no cloud credentials, provider-specific signatures or personal
// drive object keys cross this boundary. Unknown versions fail closed.
class ResourcePolicy {
  const ResourcePolicy({
    this.enabled = false,
    this.uploadEnabled = false,
    this.downloadEnabled = false,
    this.reviewRequired = true,
    this.uploaderDeleteEnabled = false,
    this.groupTransferEnabled = false,
    this.notice = '',
    this.maxFileBytes = 0,
    this.totalBytes = 0,
    this.usedBytes = 0,
    this.categories = const [],
  });
  factory ResourcePolicy.fromJson(Map<String, dynamic> json) => ResourcePolicy(
    enabled: json['enabled'] == true,
    uploadEnabled: json['upload_enabled'] == true,
    downloadEnabled: json['download_enabled'] == true,
    reviewRequired: json['review_required'] != false,
    uploaderDeleteEnabled: json['uploader_delete_enabled'] == true,
    groupTransferEnabled: json['group_transfer_enabled'] == true,
    notice: json['notice'] is String ? json['notice'] : '',
    maxFileBytes: _nonNegative(json['max_file_bytes']),
    totalBytes: _nonNegative(json['total_bytes']),
    usedBytes: _nonNegative(json['used_bytes']),
    categories: (json['categories'] as List? ?? [])
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList(),
  );
  final bool enabled, uploadEnabled, downloadEnabled, reviewRequired;
  final bool uploaderDeleteEnabled, groupTransferEnabled;
  final String notice;
  final int maxFileBytes, totalBytes, usedBytes;
  final List<String> categories;
  bool get canUpload => enabled && uploadEnabled && maxFileBytes > 0;
  bool get canDownload => enabled && downloadEnabled;
}

int _nonNegative(dynamic value) =>
    value is num && value.isFinite && value >= 0 ? value.toInt() : 0;

class PublicResource {
  PublicResource.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['file_name'] as String,
      size = _nonNegative(json['file_size']),
      checksum = json['checksum'] as String,
      status = json['status'] as String,
      canDelete = json['can_delete'] == true,
      category = json['category'] as String? ?? '',
      author = json['author_name'] as String? ?? '',
      description = json['description'] as String? ?? '',
      createdAt = json['created_at'] as String?,
      reviewNote = json['review_note'] as String? ?? '' {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        name.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) {
      throw const DriveFailure('INVALID_RESPONSE');
    }
  }
  final String id,
      name,
      checksum,
      status,
      category,
      author,
      description,
      reviewNote;
  final String? createdAt;
  final int size;
  final bool canDelete;
  bool get published => status == 'published';
}

class ResourceListing {
  ResourceListing.fromJson(Map<String, dynamic> json)
    : policy = ResourcePolicy.fromJson(
        Map<String, dynamic>.from(json['config']),
      ),
      files = (json['files'] as List)
          .map((f) => PublicResource.fromJson(Map<String, dynamic>.from(f)))
          .toList(),
      nextCursor = json['next_cursor'] as String?;
  final ResourcePolicy policy;
  final List<PublicResource> files;
  final String? nextCursor;
}

class ResourceTransfer {
  ResourceTransfer.fromJson(Map<String, dynamic> json)
    : uri = Uri.parse(json['url'] as String),
      method = json['method'] as String,
      expiresAt = DateTime.parse(json['expires_at'] as String),
      headers = Map<String, String>.from(json['headers'] ?? {}),
      fields = Map<String, String>.from(json['fields'] ?? {}),
      fileField = json['file_field'] as String? ?? 'file' {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !['GET', 'PUT', 'POST'].contains(method) ||
        expiresAt.difference(DateTime.now()).inSeconds < 10 ||
        headers.keys.any(
          (k) => [
            'authorization',
            'apikey',
            'cookie',
            'host',
            'content-length',
          ].contains(k.toLowerCase()),
        ) ||
        fileField.isEmpty) {
      throw const DriveFailure('INVALID_TRANSFER');
    }
  }
  final Uri uri;
  final String method, fileField;
  final DateTime expiresAt;
  final Map<String, String> headers, fields;
}
