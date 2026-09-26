import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/data/local/chat_store.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';
import 'package:huideng_counter/data/repositories/chat_repository.dart';
import 'package:huideng_counter/presentation/chat_voice_widgets.dart';

class CounterFake extends Fake implements CounterRepository {}

class ClientFake extends Fake implements SupabaseClient {}

class StoreFake extends Fake implements ChatStore {
  int queued = 0;
  @override
  Future<void> enqueue(
    String id,
    String room,
    String body, {
    Map<String, dynamic>? attachment,
  }) async {
    queued++;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.llfbandit.record/messages');
  for (final allow in [true, false]) {
    testWidgets(
      'releasing while permission is pending cannot start/send (allow=$allow)',
      (tester) async {
        final permission = Completer<bool>();
        final methods = <String>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          methods.add(call.method);
          if (call.method == 'hasPermission') return permission.future;
          return null;
        });
        final app = AppController(CounterFake());
        app.preferences['language'] = 'zh';
        final store = StoreFake();
        final client = ClientFake();
        final repository = ChatRepository(
          store,
          ChatRemote(client, 'test-user'),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HoldToRecord(
                app: app,
                repository: repository,
                room: 'room',
                onQueued: () {},
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('按住说话')),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(methods, contains('hasPermission'));
        await gesture.up();
        permission.complete(allow);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(methods, isNot(contains('start')));
        expect(store.queued, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        app.dispose();

        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      },
    );
  }
}
