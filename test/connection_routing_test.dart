import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_connection/connection_router.dart';
import 'package:huideng_connection/routed_transport.dart';

class FailingSocket implements WebSocketChannel {
  @override
  Future<void> get ready => Future<void>.error(StateError('handshake failed'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final canonical = Uri.parse('https://project.supabase.co');
  late SimpleKeyPair key;
  late String publicKey;
  Future<String> envelope({
    int version = 1,
    String? project,
    List<String>? origins,
    DateTime? expires,
  }) async {
    final now = DateTime.now().toUtc();
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'project': project ?? canonical.toString(),
        'version': version,
        'issued_at': now.subtract(const Duration(minutes: 1)).toIso8601String(),
        'expires_at': (expires ?? now.add(const Duration(days: 30)))
            .toIso8601String(),
        'origins':
            origins ??
            ['https://primary.example.com', 'https://backup.example.com'],
      }),
    );
    final sig = await Ed25519().sign(payload, keyPair: key);
    return jsonEncode({
      'payload': base64Encode(payload),
      'signature': base64Encode(sig.bytes),
    });
  }

  Future<ConnectionRouter> router() async {
    final r = ConnectionRouter(
      canonical: canonical,
      project: canonical.toString(),
      publicKey: publicKey,
    );
    await r.apply(await envelope());
    addTearDown(r.dispose);
    return r;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    key = await Ed25519().newKeyPair();
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
  });
  test(
    'signature/project/expiry/rollback and changed same-version data rejected',
    () async {
      final r = await router();
      await r.apply(await envelope(version: 2));
      await expectLater(
        r.apply(await envelope(version: 1)),
        throwsFormatException,
      );
      await expectLater(
        r.apply(
          await envelope(version: 2, origins: ['https://evil.example.com']),
        ),
        throwsFormatException,
      );
      await expectLater(
        r.apply(await envelope(version: 3, project: 'other')),
        throwsFormatException,
      );
      await expectLater(
        r.apply(
          await envelope(
            version: 3,
            expires: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        ),
        throwsFormatException,
      );
      final forged = jsonDecode(await envelope(version: 3)) as Map;
      forged['signature'] = base64Encode(List.filled(64, 0));
      await expectLater(r.apply(jsonEncode(forged)), throwsFormatException);
      expect(r.active.host, 'primary.example.com');
    },
  );
  test(
    'only original backend URL is routed, query and external URL preserved',
    () async {
      final r = await router();
      final signed = Uri.parse(
        '$canonical/storage/v1/object/sign/file?token=abc%2Fdef',
      );
      expect(r.route(signed).query, signed.query);
      expect(
        r
            .route(Uri.parse('wss://project.supabase.co/realtime/v1/websocket'))
            .scheme,
        'wss',
      );
      expect(
        r.route(Uri.parse('https://external.example.com/file')).host,
        'external.example.com',
      );
      expect(
        r.route(Uri.parse('http://project.supabase.co/auth/v1')).scheme,
        'http',
      );
    },
  );
  test(
    'safe GET retries once on transport failure; headers preserved',
    () async {
      final r = await router();
      final hosts = <String>[];
      final client = RoutedHttpClient(
        r,
        factory: () => MockClient((request) async {
          hosts.add(request.url.host);
          expect(request.headers['authorization'], 'Bearer session');
          if (hosts.length == 1) throw http.ClientException('unavailable');
          return http.Response('ok', 200);
        }),
      );
      addTearDown(client.close);
      final response = await client.get(
        Uri.parse('$canonical/rest/v1/posts'),
        headers: {'authorization': 'Bearer session'},
      );
      expect(response.body, 'ok');
      expect(hosts, ['primary.example.com', 'backup.example.com']);
    },
  );
  test(
    'write body forwarded once and never replayed on an ambiguous failure',
    () async {
      final r = await router();
      var count = 0;
      final client = RoutedHttpClient(
        r,
        factory: () => MockClient((request) async {
          count++;
          expect(request.body, 'message');
          throw http.ClientException('connection lost after commit');
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.post(Uri.parse('$canonical/rest/v1/rpc/send'), body: 'message'),
        throwsA(isA<http.ClientException>()),
      );
      expect(count, 1);
      expect(r.active.host, 'backup.example.com');
    },
  );
  test(
    '401 and rate limits do not change routes; redirects not followed',
    () async {
      final r = await router();
      for (final status in [401, 403, 429, 302]) {
        var count = 0;
        final client = RoutedHttpClient(
          r,
          factory: () => MockClient.streaming((request, body) async {
            count++;
            expect(request.followRedirects, false);
            return http.StreamedResponse(
              Stream.value(utf8.encode('error')),
              status,
            );
          }),
        );
        final result = await client.get(Uri.parse('$canonical/auth/v1/user'));
        expect(result.statusCode, status);
        expect(count, 1);
        expect(r.active.host, 'primary.example.com');
        client.close();
      }
    },
  );
  test('signed config and last selected route survive restart', () async {
    ConnectionRouter make() => ConnectionRouter(
      canonical: canonical,
      project: canonical.toString(),
      publicKey: publicKey,
      sources: [Uri.parse('https://config.example.com/connection.json')],
    );
    final a = make();
    await a.initialize(refreshNow: false);
    await a.apply(await envelope(version: 5));
    a.failed(a.active);
    await Future<void>.delayed(Duration.zero);
    a.dispose();
    final b = make();
    await b.initialize(refreshNow: false);
    addTearDown(b.dispose);
    expect(b.active.host, 'backup.example.com');
    await expectLater(
      b.apply(await envelope(version: 4)),
      throwsFormatException,
    );
  });
  test('no infrastructure keeps the original endpoint', () async {
    final r = ConnectionRouter(
      canonical: canonical,
      project: canonical.toString(),
    );
    addTearDown(r.dispose);
    await r.initialize();
    r.failed(canonical);
    expect(r.active, canonical);
    expect(r.configured, false);
  });
  test(
    'websocket reconnects use approved routes and retain headers/query',
    () async {
      final r = await router();
      Uri? observed;
      routedWebSocket(
        r,
        'wss://project.supabase.co/realtime/v1/websocket?apikey=public',
        {'Authorization': 'Bearer session'},
        connect: (uri, headers) {
          observed = uri;
          expect(headers['Authorization'], 'Bearer session');
          return FailingSocket();
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(observed!.host, 'primary.example.com');
      expect(observed!.scheme, 'wss');
      expect(observed!.query, 'apikey=public');
      expect(r.active.host, 'backup.example.com');
    },
  );
}
