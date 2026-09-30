import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/domain/chat_view.dart';
import 'package:huideng_counter/services/transfer_activity.dart';
import 'package:huideng_counter/presentation/chat_page.dart';
import 'package:huideng_counter/presentation/file_assistant_avatar.dart';

class _Repository extends Fake implements CounterRepository {}
class _OfflineClient extends Fake implements SupabaseClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Map<String, dynamic> room(String id, int minute, {bool pinned = false}) => {
    'id': id,
    'updated_at': '2026-09-29T12:${minute.toString().padLeft(2, '0')}:00Z',
    'pinned': pinned,
  };
  List<String> ids(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['id'] as String).toList();

  test('assistant is mixed by activity, never implicitly pinned', () {
    final rows = [
      room('group', 3),
      room(fileAssistantRoomId, 2),
      room('friend', 1),
    ];
    expect(ids(orderedChatConversations(rows, [])), [
      'group',
      fileAssistantRoomId,
      'friend',
    ]);
    rows[1] = room(fileAssistantRoomId, 4);
    expect(ids(orderedChatConversations(rows, [])), [
      fileAssistantRoomId,
      'group',
      'friend',
    ]);
    rows[1]['updated_at'] = null;
    expect(ids(orderedChatConversations(rows, [])), [
      'group',
      'friend',
      fileAssistantRoomId,
    ]);
  });

  test(
    'manual moves persist order, pins take precedence, auto restores recency',
    () {
      final rows = [
        room('group', 3),
        room(fileAssistantRoomId, 2),
        room('friend', 1),
      ];
      final manual = ['friend', fileAssistantRoomId, 'group'];
      expect(ids(orderedChatConversations(rows, manual)), manual);
      rows[1]['pinned'] = true;
      expect(ids(orderedChatConversations(rows, manual)), [
        fileAssistantRoomId,
        'friend',
        'group',
      ]);
      rows[1]['pinned'] = false;
      expect(ids(orderedChatConversations(rows, [])), [
        'group',
        fileAssistantRoomId,
        'friend',
      ]);
    },
  );

  test(
    'progress does not reshuffle activity; status changes persist only metadata per account',
    () async {
      final activity = TransferActivity.forUser('metadata-test');
      await activity.load();
      activity.update(
        id: 'one',
        name: 'video.mp4',
        state: 'transferring',
        size: 5368709120,
      );
      final at = activity.latest!['at'];
      activity.update(
        id: 'one',
        name: 'video.mp4',
        state: 'transferring',
        size: 5368709120,
        bytes: 1024,
      );
      expect(activity.latest!['at'], at);
      expect(activity.latest!['bytes'], 1024);
      activity.update(
        id: 'one',
        name: 'video.mp4',
        state: 'complete',
        size: 5368709120,
        bytes: 5368709120,
      );
      await activity.flushed;
      final preferences = await SharedPreferences.getInstance();
      final data =
          jsonDecode(
                preferences.getString('chat.transfer.activity.metadata-test')!,
              )
              as List;
      expect(data.single['state'], 'complete');
      expect(data.single['size'], 5368709120);
      expect(TransferActivity.forUser('different-account').records, isEmpty);
    },
  );

  test(
    'restart restores history but never shows a stale running transfer',
    () async {
      SharedPreferences.setMockInitialValues({
        'chat.transfer.activity.restore-test': jsonEncode([
          {
            'id': 'a',
            'name': 'a.zip',
            'state': 'transferring',
            'at': '2026-09-29T12:00:00Z',
          },
          {
            'id': 'b',
            'name': 'b.zip',
            'state': 'complete',
            'at': '2026-09-29T11:00:00Z',
          },
        ]),
      });
      final activity = TransferActivity.forUser('restore-test');
      await activity.load();
      expect(activity.latest!['state'], 'interrupted');
      expect(activity.records['b']!['state'], 'complete');
    },
  );

  testWidgets(
    'offline assistant is a list row with persistent pin menu on both platforms',
    (tester) async {
      final client = _OfflineClient();
      final app = AppController(_Repository());
      app.preferences['language'] = 'zh';
      await tester.pumpWidget(
        MaterialApp(
          home: ChatHome(app: app, client: client, userId: 'ui-test'),
        ),
      );
      await tester.pumpAndSettle();
      final assistant = find.byKey(const ValueKey('chat-file-assistant'));
      expect(assistant, findsOneWidget);
      expect(
        find.ancestor(of: assistant, matching: find.byType(ListView)),
        findsOneWidget,
      );
      expect(find.byType(FileAssistantAvatar), findsOneWidget);
      expect(find.text('未完成的文件直传'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.longPress(assistant);
      await tester.pumpAndSettle();
      expect(find.text('上移'), findsOneWidget);
      expect(find.text('下移'), findsOneWidget);
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'chat.assistant.pin.ui-test',
        ),
        true,
      );
      await tester.longPress(assistant);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'chat.assistant.pin.ui-test',
        ),
        false,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
