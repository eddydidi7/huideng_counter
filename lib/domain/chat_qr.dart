class ChatQr {
  const ChatQr(this.kind, this.id);
  final String kind, id;
  String get value => 'huideng://chat/$kind/$id?v=1';
  static ChatQr? parse(String text) {
    if (text.length > 200) return null;
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.scheme != 'huideng' ||
        uri.host != 'chat' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.query != 'v=1' ||
        uri.pathSegments.length != 2) {
      return null;
    }
    final kind = uri.pathSegments[0], id = uri.pathSegments[1];
    if (!['contact', 'group'].contains(kind) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id)) {
      return null;
    }
    return ChatQr(kind, id);
  }
}
