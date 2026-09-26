class DriveUpload {
  DriveUpload({
    required this.id,
    required this.path,
    required this.name,
    required this.size,
    required this.checksum,
    this.state = 'waiting',
    this.category = '',
    this.description = '',
  });
  final String id, path, name, checksum;
  final String category, description;
  final int size;
  String state;
  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'size': size,
    'checksum': checksum,
    'state': state,
    'category': category,
    'description': description,
  };
  factory DriveUpload.fromJson(Map<String, dynamic> j) => DriveUpload(
    id: j['id'],
    path: j['path'],
    name: j['name'],
    size: (j['size'] as num).toInt(),
    checksum: j['checksum'],
    state: j['state'] == 'done' ? 'done' : 'failed',
    category: j['category'] as String? ?? '',
    description: j['description'] as String? ?? '',
  );
}

class DriveFailure implements Exception {
  const DriveFailure(this.code);
  final String code;
  @override
  String toString() => 'DriveFailure($code)';
}
