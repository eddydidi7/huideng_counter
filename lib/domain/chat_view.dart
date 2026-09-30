List<Map<String, dynamic>> visibleChatRooms(
  List<Map<String, dynamic>> rooms,
  Map<String, Map<String, dynamic>> views,
) {
  final result = rooms.where((r) {
    final hidden = DateTime.tryParse(
      views[r['id']]?['hiddenThrough'] as String? ?? '',
    );
    final updated = DateTime.tryParse(r['updated_at'] as String? ?? '');
    return hidden == null || updated == null || updated.isAfter(hidden);
  }).toList();
  result.sort((a, b) {
    final pinned =
        (b['pinned'] == true ? 1 : 0) - (a['pinned'] == true ? 1 : 0);
    if (pinned != 0) return pinned;
    final unread =
        (roomUnread(b, views[b['id']]) > 0 ? 1 : 0) -
        (roomUnread(a, views[a['id']]) > 0 ? 1 : 0);
    if (unread != 0) return unread;
    return (DateTime.tryParse(b['updated_at'] as String? ?? '') ??
            DateTime(1970))
        .compareTo(
          DateTime.tryParse(a['updated_at'] as String? ?? '') ?? DateTime(1970),
        );
  });
  return result;
}

bool chatMessageVisible(Map<String, dynamic> message, String? clearedThrough) {
  if (message['recalled_at'] != null) return false;
  if (message['pending'] == true) return true;
  final cutoff = DateTime.tryParse(clearedThrough ?? '');
  final date = DateTime.tryParse(message['created_at'] as String? ?? '');
  return cutoff == null || date == null || date.isAfter(cutoff);
}

String chatPreview(Map<String, dynamic> room, Map<String, dynamic>? view) {
  return chatMessageVisible({
        'created_at': room['updated_at'],
      }, view?['clearedThrough'] as String?)
      ? room['preview'] as String? ?? ''
      : '';
}

int roomUnread(Map<String, dynamic> room, Map<String, dynamic>? view) {
  final actual = (room['unread'] as num? ?? 0).toInt();
  return actual > 0
      ? actual
      : view?['manualUnread'] == true
      ? 1
      : 0;
}

String chatListTime(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return '';
  final now = DateTime.now();
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
  return '${date.month}/${date.day}';
}

const fileAssistantRoomId = 'local:file-assistant';

List<Map<String, dynamic>> orderedChatConversations(
  List<Map<String, dynamic>> rooms,
  List<String> manualOrder,
) {
  final ranks = {
    for (var i = 0; i < manualOrder.length; i++) manualOrder[i]: i,
  };
  return rooms.toList()..sort((a, b) {
    final pinned =
        (b['pinned'] == true ? 1 : 0) - (a['pinned'] == true ? 1 : 0);
    if (pinned != 0) return pinned;
    if (manualOrder.isNotEmpty) {
      final rank = (ranks[a['id']] ?? manualOrder.length).compareTo(
        ranks[b['id']] ?? manualOrder.length,
      );
      if (rank != 0) return rank;
    }
    final date = (b['updated_at'] as String? ?? '').compareTo(
      a['updated_at'] as String? ?? '',
    );
    return date != 0 ? date : (a['id'] as String).compareTo(b['id'] as String);
  });
}
