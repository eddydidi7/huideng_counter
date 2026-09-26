import 'support/forum_memory_draft.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/data/local/forum_draft_store.dart';
import 'package:huideng_counter/presentation/forum_compose_page.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'forum_test.dart' show UnusedCounter, PublishingRepository;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  test(
    'draft text/style/order survive reopened database; accounts isolated',
    () async {
      final dir = await Directory.systemTemp.createTemp('forum-draft-test-');
      final cache = await ChatStore.openAt('${dir.path}/draft.sqlite', 'a');
      final store = ForumDraftStore(cache, dir);
      final source = await store.image(Uint8List.fromList([1, 2, 3]));
      final draft = {
        'body': '离线内容',
        'request': 'stable-id',
        'files': [
          {'source': source, 'id': '2'},
          {'id': '1'},
        ],
        'card': {
          'text': '甲\f乙',
          'style': {'size': 20},
        },
      };
      await store.write('new', draft);
      await cache.db.close();
      final reopened = await ChatStore.openAt('${dir.path}/draft.sqlite', 'a');
      expect(await ForumDraftStore(reopened, dir).read('new'), draft);
      expect(await File(source).readAsBytes(), [1, 2, 3]);
      expect(
        await ForumDraftStore(ChatStore(reopened.db, 'b'), dir).read('new'),
        isNull,
      );
      await reopened.db.close();
    },
  );
  testWidgets(
    'compose restores unsent draft on small screen and retains failed publication',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryDraft();
      final app = AppController(UnusedCounter());
      await store.write('v1:new', {
        'title': '保留标题',
        'body': '离线正文',
        'request': 'stable',
        'kind': 'status',
        'category': 'feedback',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ForumComposePage(
            app: app,
            repository: PublishingRepository(),
            categories: const {
              'feedback': ['综合', 'General'],
            },
            openDraft: (_) async => store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留标题'), findsOneWidget);
      expect(find.text('离线正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.widgetWithText(TextFormField, '离线正文'),
        '更改后仍在本机',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('forum-publish')));
      await tester.pumpAndSettle();
      expect(find.text('确认发布'), findsNothing);
      await tester.pumpAndSettle();
      expect((await store.read('v1:new'))!['body'], '更改后仍在本机');
      expect(find.textContaining('发布失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      app.dispose();
    },
  );
}
