import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/core/cloud_controller.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';
import 'package:huideng_counter/presentation/chat_avatar.dart';
import 'package:huideng_counter/presentation/profile_navigation.dart';
import 'package:huideng_counter/presentation/public_profile_page.dart';
import 'package:huideng_counter/presentation/public_profile_link_page.dart';
import 'forum_test.dart' show UnusedCounter;

class TestCloud extends ChangeNotifier implements CloudController {
  TestCloud(this.client);
  @override
  SupabaseClient? client;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PeerRemote extends ChatRemote {
  PeerRemote(SupabaseClient client) : super(client, 'me');
  List<Map<String, String>> members = [
    {'user_id': 'me'},
    {'user_id': 'peer'},
  ];
  @override
  void checkUser() {}
  @override
  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async => members;
}

class RouteCounter extends NavigatorObserver {
  int profiles = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name?.startsWith('/profile/') == true) profiles++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController app;
  late SupabaseClient client;
  late TestCloud cloud;
  final requests = <String>[];
  var wrappedPublic = false;
  setUp(() async {
    requests.clear();
    wrappedPublic = false;
    app = AppController(UnusedCounter());
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token =
        '${part({'alg': 'HS256'})}.${part({'sub': 'me', 'exp': 4102444800})}.test';
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        requests.add(path);
        Object? result;
        if (path.contains('/auth/')) {
          result = {
            'access_token': token,
            'refresh_token': 'r',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': 'me',
              'aud': 'authenticated',
              'role': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-09-28T00:00:00Z',
            },
          };
        } else if (path.endsWith('/community_profile_v1')) {
          final id = (jsonDecode(request.body) as Map)['p_user'];
          result = {
            'profile': {
              'nickname': 'Name $id',
              'personal_number': '123456',
              'bio': 'Existing bio',
            },
            'posts': [],
          };
        } else if (path.endsWith('/community_public_profile_v1')) {
          const p = {
            'nickname': 'Public name',
            'personal_number': '654321',
            'bio': 'Public bio',
          };
          result = wrappedPublic ? {'profile': p} : p;
        } else if (path.endsWith('/community_profile_public_id_v1')) {
          result = 'public-id';
        } else if (path.endsWith('/community_social_v1')) {
          result = {'following_count': 0, 'followers': 0, 'following': false};
        } else if (path.endsWith('/chat_contacts_v1')) {
          final action = (jsonDecode(request.body) as Map)['p_action'];
          result = action == 'list'
              ? {
                  'friends': [
                    {'user_id': 'friend'},
                  ],
                }
              : {};
        } else if (path.endsWith('/public_forum_avatar')) {
          result = null;
        } else {
          result = [];
        }
        return http.Response(
          jsonEncode(result),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'a@example.test',
      password: 'test',
    );
    cloud = TestCloud(client);
    app.cloud = cloud;
  });
  tearDown(() async {
    app.dispose();
    cloud.dispose();
    await client.dispose();
  });

  testWidgets(
    'avatar beats row tap; long press and return preserve search/scroll',
    (tester) async {
      final search = TextEditingController(text: 'saved search');
      final scroll = ScrollController();
      final routes = RouteCounter();
      var taps = 0, holds = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: app.navigatorKey,
          navigatorObservers: [routes],
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: search),
                Expanded(
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: 40,
                    itemBuilder: (_, i) => ListTile(
                      onTap: () => taps++,
                      onLongPress: () => holds++,
                      title: Text('Row $i'),
                      leading: ChatAvatar(
                        app: app,
                        userId: 'peer-$i',
                        key: ValueKey('avatar-$i'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(500);
      await tester.pumpAndSettle();
      final avatar = find.byType(ChatAvatar).hitTestable().first;
      final id = tester.widget<ChatAvatar>(avatar).userId;
      final offset = scroll.offset;
      await tester.longPress(avatar);
      await tester.pumpAndSettle();
      expect(holds, 1);
      expect(routes.profiles, 0);
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(routes.profiles, 1);
      expect(
        tester.widget<PublicProfilePage>(find.byType(PublicProfilePage)).userId,
        id,
      );
      expect(find.text('个人号：123456'), findsOneWidget);
      expect(find.text('Existing bio'), findsOneWidget);
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      expect(routes.profiles, 1);
      app.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(search.text, 'saved search');
      expect(scroll.offset, offset);
      await tester.tap(find.text('Row ${id!.split('-').last}'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      search.dispose();
    },
  );

  testWidgets(
    'unknown identity gives feedback without opening a wrong profile',
    (tester) async {
      var rowTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InkWell(
              onTap: () => rowTaps++,
              child: ChatAvatar(app: app),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      expect(rowTaps, 0);
      expect(find.byType(PublicProfilePage), findsNothing);
      expect(find.text('暂时无法确定该用户，请稍后重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final id in ['me', 'friend', 'stranger']) {
    testWidgets('one profile component and correct relationship for $id', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: app.navigatorKey,
          home: Scaffold(
            body: ChatAvatar(app: app, userId: id, groupId: 'group-context'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      final page = tester.widget<PublicProfilePage>(
        find.byType(PublicProfilePage),
      );
      expect(page.userId, id);
      expect(page.groupId, 'group-context');
      expect(find.text(id == 'me' ? '我的个人主页' : '个人主页'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-message-button')),
        id == 'me' ? findsNothing : findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-friend-chip')),
        id == 'friend' ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('profile-add-friend-button')),
        id == 'stranger' ? findsOneWidget : findsNothing,
      );
      if (id == 'me') {
        expect(find.byTooltip('更换头像'), findsOneWidget);
        await tester.tap(find.byType(ChatAvatar));
        await tester.pumpAndSettle();
        expect(find.byType(ChatAvatarPage), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('selection checkbox stays independent of avatar', (tester) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: app.navigatorKey,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => CheckboxListTile(
              secondary: ChatAvatar(app: app, userId: 'peer'),
              title: const Text('Select member'),
              value: selected,
              onChanged: (v) => update(() => selected = v!),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ChatAvatar));
    await tester.pumpAndSettle();
    expect(selected, false);
    app.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(selected, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'direct-room avatar resolves the peer; group avatar keeps row action',
    (tester) async {
      final remote = PeerRemote(client);
      final avatar = ChatAvatar(app: app, remote: remote, roomId: 'direct');
      expect(await avatar.resolveUserId(), 'peer');
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: app.navigatorKey,
          home: Scaffold(body: avatar),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PublicProfilePage>(find.byType(PublicProfilePage)).userId,
        'peer',
      );
      remote.members.add({'user_id': 'another'});
      expect(await avatar.resolveUserId(), isNull);
      var groupTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InkWell(
              onTap: () => groupTaps++,
              child: ChatAvatar(app: app, groupAvatar: true, roomId: 'group'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      expect(groupTaps, 1);
      expect(find.byType(PublicProfilePage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final wrapped in [false, true]) {
    testWidgets(
      'public link reuses profile UI without authenticated RPCs, wrapped=$wrapped',
      (tester) async {
        wrappedPublic = wrapped;
        requests.clear();
        await tester.pumpWidget(
          MaterialApp(
            home: PublicProfileLinkPage(app: app, publicId: 'public'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PublicProfilePage), findsOneWidget);
        expect(find.text('Public name'), findsOneWidget);
        expect(find.text('个人号：654321'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('profile-message-button')),
          findsNothing,
        );
        expect(requests, ['/rest/v1/rpc/community_public_profile_v1']);
        await tester.tap(find.byType(ChatAvatar));
        await tester.pumpAndSettle();
        expect(find.byType(PublicProfilePage), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'above-navigator avatar exposes profile then restores its overlay',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: app.navigatorKey,
          home: const Scaffold(body: Text('Underlying page')),
          builder: (_, child) => ValueListenableBuilder<int>(
            valueListenable: profileOverlayDepth,
            builder: (_, depth, _) => Stack(
              children: [
                child!,
                if (depth == 0)
                  Material(
                    child: Center(
                      child: ChatAvatar(app: app, userId: 'peer'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChatAvatar));
      await tester.pumpAndSettle();
      expect(profileOverlayDepth.value, 1);
      expect(find.text('Name peer'), findsOneWidget);
      app.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(profileOverlayDepth.value, 0);
      expect(find.byType(ChatAvatar), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
