import 'package:huideng_counter/data/remote/chat_live.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/services/chat_guest_session.dart';
import 'package:huideng_counter/presentation/chat_guest_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Device nickname excludes controls, deduplicates manufacturer, caps length',
    () {
      expect(guestDeviceNickname('Xiaomi', 'Xiaomi 14T'), 'Xiaomi 14T');
      expect(guestDeviceNickname('Xiaomi', '2406APNFAG'), 'Xiaomi 2406APNFAG');
      expect(guestDeviceNickname('', 'iPhone 16'), 'iPhone 16');
      expect(guestDeviceNickname('', ''), '手机学友');
      expect(guestDeviceNickname('Xiaomi\n', '14T\t'), 'Xiaomi 14T');
      expect(guestDeviceNickname('', '机' * 80).runes.length, 40);
    },
  );
  test(
    'Concurrent and repeat opens reuse one authenticated guest session',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          expect((body['data'] as Map).keys, ['chat_device_nickname']);
          return http.Response(
            jsonEncode({
              'access_token': 'test-access',
              'refresh_token': 'test-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': '00000000-0000-4000-8000-000000000001',
                'aud': 'authenticated',
                'role': 'authenticated',
                'is_anonymous': true,
                'app_metadata': {},
                'user_metadata': body['data'],
                'created_at': '2026-09-18T00:00:00Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await Future.wait([
        ChatGuestSession.ensure(client),
        ChatGuestSession.ensure(client),
      ]);
      expect(client.auth.currentUser!.isAnonymous, true);
      await ChatGuestSession.ensure(client);
      expect(requests, 1);
      final live = ChatLive(
        ChatRemote(client, client.auth.currentUser!.id),
        invisible: true,
      );
      expect(live.invisible, false);
      await expectLater(live.setInvisible(true), throwsStateError);
      expect(live.invisible, false);

      await client.dispose();
    },
  );
  testWidgets(
    'Guest gate reports disabled backend then retries without registration',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatGuestGate(
            connect: () async {
              calls++;
              throw const AuthException(
                'disabled',
                code: 'anonymous_provider_disabled',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('免注册聊天尚未开通，请管理员开启访客登录。'), findsOneWidget);
      expect(calls, 1);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
