import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/remote/chat_live.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';

class FakeLive extends ChatLive {
  FakeLive({super.invisible})
    : super(
        ChatRemote(
          SupabaseClient('https://example.supabase.co', 'test'),
          'user',
        ),
      );
  final actions = <String>[];
  Completer<void>? gate;
  @override
  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    actions.add(action);
    if (action == 'heartbeat' && gate != null) await gate!.future;
    return {
      'online': <String>[],
      'peers': <String, dynamic>{},
      'offers': <dynamic>[],
    };
  }
}

void main() {
  test(
    'hidden preference polls without announcing presence; online restores heartbeat',
    () async {
      final live = FakeLive(invisible: true);
      await live.heartbeat(['friend']);
      expect(live.actions, ['status']);
      await live.setInvisible(false);
      expect(live.actions.last, 'heartbeat');
      await live.setInvisible(true);
      await live.heartbeat(['friend']);
      expect(live.actions, ['status', 'heartbeat', 'offline', 'status']);
      live.dispose();
    },
  );
  test(
    'hiding waits for pending heartbeat so it cannot restore online presence',
    () async {
      final live = FakeLive();
      live.gate = Completer<void>();
      final pending = live.heartbeat([]);
      await Future<void>.delayed(Duration.zero);
      final hiding = live.setInvisible(true);
      expect(live.invisible, isTrue);
      expect(live.actions, ['heartbeat']);
      live.gate!.complete();
      await pending;
      await hiding;
      expect(live.actions, ['heartbeat', 'offline']);
      live.dispose();
    },
  );
}
