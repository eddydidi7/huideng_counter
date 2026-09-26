import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/note_grid.dart';

void main() {
  for (final width in [320.0, 412.0]) {
    testWidgets('Two columns and four full rows at $width', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteGrid(
              count: 12,
              builder: (_, i) => NoteGridCard(
                key: ValueKey(i),
                title: Text(
                  '笔记标题 $i',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                summary: '正文摘要测试，多行内容保持清晰。' * 5,
                date: '2026/9/18',
                menu: PopupMenuButton(
                  itemBuilder: (_) => [const PopupMenuItem(child: Text('收藏'))],
                ),
              ),
            ),
          ),
        ),
      );
      final first = tester.getRect(find.byKey(const ValueKey(0)));
      final second = tester.getRect(find.byKey(const ValueKey(1)));
      final last = tester.getRect(find.byKey(const ValueKey(7)));
      expect(first.top, second.top);
      expect(first.right, lessThan(second.left));
      expect(last.bottom, lessThanOrEqualTo(640));
      expect(last.bottom, greaterThan(620));
      expect(tester.takeException(), isNull);
    });
  }
}
