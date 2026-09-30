import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/note_actions_menu.dart';

void main() {
  test('quick menu actions reflect state and share channels stay nested', () {
    final normal = noteQuickActions({});
    expect(
      normal.map((e) => e.label),
      containsAll(['置顶', '收藏', '归档', '添加到快速访问', '选择笔记']),
    );
    expect(normal.where((e) => e.action == 'share').single.submenu, isTrue);
    expect(
      normal.any((e) => e.action == 'redbook' || e.action == 'chat'),
      isFalse,
    );
    final active = noteQuickActions({
      'isPinned': 1,
      'isFavorite': 1,
      'isArchived': 1,
      'source_meta': '{"quick_access":true}',
    });
    expect(
      active.map((e) => e.label),
      containsAll(['取消置顶', '取消收藏', '取消归档', '取消快速访问']),
    );
    expect(active.map((e) => e.label), isNot(contains('置顶')));
    expect(noteQuickActions({}, trash: true).map((e) => e.action), [
      'restore',
      'select',
    ]);
  });
}
