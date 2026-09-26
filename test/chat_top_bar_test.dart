import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/chat_top_bar.dart';

void main() {
  for (final width in [320.0, 360.0, 412.0]) {
    for (final english in [false, true]) {
      testWidgets(
        'top shortcuts fit $width english=$english with back button',
        (tester) async {
          tester.view.physicalSize = Size(width, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final calls = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                appBar: AppBar(
                  leading: const BackButton(),
                  titleSpacing: 4,
                  title: ChatTopBar(
                    english: english,
                    onProfile: () => calls.add('profile'),
                    onContacts: () => calls.add('contacts'),
                    onResources: () => calls.add('resources'),
                    onCommunity: () => calls.add('community'),
                    onSearch: () => calls.add('search'),
                    onAdd: calls.add,
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byTooltip(english ? 'Profile' : '个人主页'));
          final addBox = tester.getRect(find.byType(PopupMenuButton<String>));
          expect(addBox.width, 52);
          expect(addBox.right, lessThanOrEqualTo(width - 8));
          expect(addBox.height, 48);
          for (final button in find.byType(TextButton).evaluate()) {
            final finder = find.byWidget(button.widget);
            final box = tester.getRect(finder);
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(width));
            expect(box.height, greaterThanOrEqualTo(44));
            await tester.tap(finder);
          }
          await tester.tap(find.byTooltip(english ? 'Search' : '搜索'));
          await tester.tap(find.byTooltip(english ? 'Add' : '添加'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(english ? 'Add friend' : '添加好友'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(english ? 'Add' : '添加'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(english ? 'Stranger message settings' : '陌生人聊天开关'),
          );
          await tester.pumpAndSettle();
          expect(calls, ['profile', 'resources', 'search', 'add', 'privacy']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
