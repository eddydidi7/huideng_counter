enum ShareTarget {
  chat,
  redbook,
  note,
  personalDrive,
  publicLibrary,
  group,
  webLink,
}

class ContentReference {
  final String type, id, title, summary;
  final String? slug;
  const ContentReference({
    required this.type,
    required this.id,
    required this.title,
    this.summary = '',
    this.slug,
  });
  String get link => 'huideng://$type/$id${slug == null ? '' : '?slug=$slug'}';
}
