import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/data/local/local_database.dart';
import 'package:huideng_counter/data/remote/group_admin.dart';
import 'package:huideng_counter/data/repositories/sqlite_counter_repository.dart';
import 'package:huideng_counter/presentation/group_admin_page.dart';
import 'package:huideng_counter/services/group_operation_error.dart';

const me = '00000000-0000-4000-8000-000000000001';
const room = '11111111-1111-4111-8111-111111111111';

String token() {
  String part(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': me, 'role': 'authenticated', 'exp': 4102444800})}.test';
}

Future<SupabaseClient> fakeClient(
  List<Map<String, dynamic>> calls,
  Object? Function(String action, Map data) reply,
) async {
  final client = SupabaseClient(
    'https://example.test',
    'test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      if (request.url.path.contains('/auth/')) {
        return http.Response(
          jsonEncode({
            'access_token': token(),
            'refresh_token': 'r',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-09-19T00:00:00Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (!request.url.path.contains('/rpc/')) {
        return http.Response('[]', 200, request: request, headers: {'content-type': 'application/json'});
      }
      final body = jsonDecode(request.body) as Map;
      final action = body['p_action'] as String;
      calls.add({'action': action, 'data': body['p_data']});
      return http.Response(
        jsonEncode(reply(action, body['p_data'] as Map)),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  await client.auth.signInWithPassword(email: 'a@example.test', password: 'x');
  return client;
}

Map<String, dynamic> person(String id, String name, String role, {String? muted}) => {
  'user_id': id,
  'nickname': name,
  'role': role,
  'joined_at': '2026-09-20T00:00:00Z',
  'muted_until': muted,
  'exempt_all_mute': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  test('readable server rules and audit text', () {
    expect(groupOperationError(Exception('GROUP_ADMIN_LIMIT')), '每个群最多设置 10 位管理员');
    expect(groupAdminMessage('PostgrestException(message: GROUP_ALL_MUTED)'), contains('全员禁言'));
    expect(groupAdminMessage('other'), isNull);
    expect(groupMuteOptions.values, containsAll([10, 60, 720, 1440, 4320, 10080, -1]));
    expect(
      groupLogText({'action': 'mute', 'actor_name': '管理员甲', 'target_name': '成员乙', 'detail': {'until': 'infinity'}}),
      '管理员甲 禁言了 成员乙（永久）',
    );
    expect(groupLogText({'action': 'all_mute', 'actor_name': '群主', 'detail': {'enabled': true}}), '群主 开启了全员禁言');
    expect(mutedText('infinity'), '永久禁言');
    expect(mutedText('2000-01-01T00:00:00Z'), isNull);
  });

  testWidgets('members: owner/admins first, roles labelled, batch mute for managers', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <Map<String, dynamic>>[];
    final client = await tester.runAsync(
      () => fakeClient(calls, (action, data) => switch (action) {
        'members' => {
          'managers': [person(me, '群主甲', 'owner'), person('a1', '管理员乙', 'admin')],
          'items': [person('m1', '成员丙', 'member', muted: 'infinity'), person('m2', '成员丁', 'member')],
          'total': 4,
        },
        'mute' => {'done': 2, 'skipped': 0},
        _ => {},
      }),
    );
    final db = await tester.runAsync(() => LocalDatabase.openAt(inMemoryDatabasePath));
    final app = AppController(SqliteCounterRepository(db!));
    final admin = GroupAdmin(client!, room);
    await tester.pumpWidget(
      MaterialApp(home: GroupMembersPage(app: app, admin: admin, myRole: 'owner')),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('群成员（4）'), findsOneWidget);
    expect(find.text('群主和管理员'), findsOneWidget);
    expect(find.text('群主'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.textContaining('永久禁言'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('管理员乙')).dy,
      lessThan(tester.getTopLeft(find.text('成员丙')).dy),
    );
    expect(calls.first['data']['room_id'], room);

    await tester.tap(find.text('批量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成员丙'));
    await tester.tap(find.text('成员丁'));
    await tester.tap(find.text('群主甲')); // not manageable: ignored
    await tester.pump();
    expect(find.text('已选择 2 人'), findsOneWidget);
    await tester.tap(find.text('批量禁言'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1小时'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final mute = calls.lastWhere((c) => c['action'] == 'mute');
    expect((mute['data']['user_ids'] as List).toSet(), {'m1', 'm2'});
    expect(mute['data']['minutes'], 60);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await client.dispose();
      await db.close();
    });
  });

  testWidgets('initialSelecting opens straight into batch-remove mode for a manager', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final client = await tester.runAsync(
      () => fakeClient(calls, (action, data) => switch (action) {
        'members' => {
          'managers': [person(me, '群主甲', 'owner')],
          'items': [person('m1', '成员丙', 'member'), person('m2', '成员丁', 'member')],
          'total': 3,
        },
        'remove' => {'done': 1, 'skipped': 0},
        _ => {},
      }),
    );
    final db = await tester.runAsync(() => LocalDatabase.openAt(inMemoryDatabasePath));
    final app = AppController(SqliteCounterRepository(db!));
    await tester.pumpWidget(
      MaterialApp(
        home: GroupMembersPage(
          app: app,
          admin: GroupAdmin(client!, room),
          myRole: 'owner',
          initialSelecting: true,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    // Straight into selection mode: no extra tap on "批量" needed.
    expect(find.text('已选择 0 人'), findsOneWidget);
    expect(find.text('批量移出'), findsOneWidget);
    await tester.tap(find.text('成员丙'));
    await tester.pump();
    expect(find.text('已选择 1 人'), findsOneWidget);
    await tester.tap(find.text('批量移出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final remove = calls.lastWhere((c) => c['action'] == 'remove');
    expect(remove['data']['user_ids'], ['m1']);
    expect(remove['data']['ban'], false);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await client.dispose();
      await db.close();
    });
  });

  testWidgets('initialSelecting is ignored when picking a member (e.g. transfer ownership)', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final client = await tester.runAsync(
      () => fakeClient(calls, (action, data) => {
        'managers': [person(me, '群主甲', 'owner')],
        'items': [person('m1', '成员丙', 'member')],
        'total': 2,
      }),
    );
    final db = await tester.runAsync(() => LocalDatabase.openAt(inMemoryDatabasePath));
    final app = AppController(SqliteCounterRepository(db!));
    await tester.pumpWidget(
      MaterialApp(
        home: GroupMembersPage(
          app: app,
          admin: GroupAdmin(client!, room),
          myRole: 'owner',
          pickTitle: '选择新群主',
          initialSelecting: true,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('选择新群主'), findsOneWidget);
    expect(find.text('批量移出'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await client.dispose();
      await db.close();
    });
  });

  testWidgets('ordinary members see no batch or management actions', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final client = await tester.runAsync(
      () => fakeClient(calls, (action, data) => {
        'managers': [person('o', '群主甲', 'owner')],
        'items': [person(me, '我', 'member'), person('m2', '成员丁', 'member')],
        'total': 3,
      }),
    );
    final db = await tester.runAsync(() => LocalDatabase.openAt(inMemoryDatabasePath));
    final app = AppController(SqliteCounterRepository(db!));
    await tester.pumpWidget(
      MaterialApp(home: GroupMembersPage(app: app, admin: GroupAdmin(client!, room), myRole: 'member')),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('批量'), findsNothing);
    await tester.tap(find.text('成员丁'));
    await tester.pumpAndSettle();
    expect(find.text('查看个人主页'), findsOneWidget);
    expect(find.text('禁言…'), findsNothing);
    expect(find.text('设为管理员'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await client.dispose();
      await db.close();
    });
  });
}
