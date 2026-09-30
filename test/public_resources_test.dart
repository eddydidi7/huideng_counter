import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/data/local/drive_upload_queue.dart';
import 'package:huideng_counter/data/remote/public_resource_api.dart';
import 'package:huideng_counter/domain/cloud_file.dart';
import 'package:huideng_counter/domain/public_resource.dart';
import 'package:huideng_counter/presentation/public_resources_page.dart';

const content = [1, 2, 3, 4];
Map<String, dynamic> fileJson({String status = 'published'}) => {
  'id': 'resource-a',
  'file_name': '学修资料.pdf',
  'file_size': content.length,
  'checksum': sha256.convert(content).toString(),
  'status': status,
  'category': '经论',
  'author_name': '分享者',
  'description': '学习资料说明',
  'review_note': status == 'rejected' ? '请补充资料说明' : '',
};
Map<String, dynamic> response({
  bool enabled = true,
  bool upload = true,
  bool download = true,
  bool review = false,
  List<Map<String, dynamic>>? files,
}) => {
  'api_version': 1,
  'config': {
    'enabled': enabled,
    'upload_enabled': upload,
    'download_enabled': download,
    'review_required': review,
    'uploader_delete_enabled': true,
    'group_transfer_enabled': true,
    'max_file_bytes': 1073741824,
    'total_bytes': 107374182400,
    'used_bytes': 1024,
    'categories': ['经论', '音频'],
  },
  'files': files ?? [fileJson()],
  'next_cursor': null,
};
Map<String, dynamic> transfer(
  String method, {
  String host = 'storage.example.test',
}) => {
  'url': 'https://$host/signed-object?signature=example',
  'method': method,
  'expires_at': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'headers': {'x-resource-test': 'temporary'},
  'fields': {'policy': 'example'},
};
Matcher failure(String code) =>
    isA<DriveFailure>().having((e) => e.code, 'code', code);

class FakeLibrary implements ResourceLibraryApi, ResourceDeletionApi {
  final deleted = <String>[];
  @override
  Future<void> deleteResource(PublicResource file) async {
    deleted.add(file.id);
    data = {...data, 'files': <Map<String, dynamic>>[]};
  }

  Map<String, dynamic> data = response();
  List<Map<String, dynamic>>? mineFiles;
  final queries = <String>[];
  @override
  String get owner => 'member-a';
  @override
  void guard() {}
  @override
  void close() {}
  @override
  Future<ResourceListing> list({
    bool mine = false,
    String search = '',
    String category = '',
    String sort = 'time',
    String? cursor,
  }) async {
    queries.add('$mine|$search|$category|$sort');
    return ResourceListing.fromJson({
      ...data,
      if (mine && mineFiles != null) 'files': mineFiles,
    });
  }

  @override
  Future<PublicResource> upload(
    DriveUpload task,
    void Function(double) progress,
  ) => throw UnimplementedError();
  @override
  Future<String> download(
    PublicResource file,
    void Function(double) progress,
  ) => throw UnimplementedError();
}

void main() {
  test(
    'web share requests a stable page URL, not a temporary object URL',
    () async {
      final api = PublicResourceApi(
        owner: 'u',
        checkSession: () {},
        call: (body) async {
          expect(body['action'], 'share');
          expect(body['id'], 'resource-a');
          return {
            'api_version': 1,
            'url': 'https://wenshu-web-service.onrender.com/f/${'a' * 64}',
          };
        },
      );
      addTearDown(api.close);
      expect(
        await api.webShare(PublicResource.fromJson(fileJson())),
        contains('/f/'),
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'public uploads are isolated from private queue and other accounts',
    () async {
      final task = DriveUpload(
        id: 'stable-upload',
        path: '/source',
        name: 'book',
        size: 4,
        checksum: 'hash',
        category: '经论',
        description: '说明',
      );
      await DriveUploadQueue('A').save([task]);
      expect(
        await DriveUploadQueue('A', publicResources: true).read(),
        isEmpty,
      );
      await DriveUploadQueue('A', publicResources: true).save([task]);
      expect(
        await DriveUploadQueue('B', publicResources: true).read(),
        isEmpty,
      );
      final reopened = (await DriveUploadQueue(
        'A',
        publicResources: true,
      ).read()).single;
      expect(reopened.id, task.id);
      expect(reopened.category, '经论');
      expect(reopened.description, '说明');
    },
  );
  test(
    'not deployed becomes closed; network failures do not masquerade as closed',
    () async {
      final api = PublicResourceApi(
        owner: 'A',
        checkSession: () {},
        call: (_) async => throw const DriveFailure('RESOURCE_NOT_CONFIGURED'),
      );
      addTearDown(api.close);
      expect((await api.list()).policy.enabled, isFalse);
      final network = PublicResourceApi(
        owner: 'A',
        checkSession: () {},
        call: (_) async => throw const SocketException('offline'),
      );
      addTearDown(network.close);
      await expectLater(
        network.list(),
        throwsA(
          isA<DriveFailure>().having((e) => e.code, 'code', 'NETWORK_FAILED'),
        ),
      );
    },
  );
  test(
    'public listing rejects leaked pending files, mine supports moderation status',
    () async {
      final api = PublicResourceApi(
        owner: 'A',
        checkSession: () {},
        call: (_) async => response(files: [fileJson(status: 'pending')]),
      );
      addTearDown(api.close);
      await expectLater(api.list(), throwsA(failure('INVALID_RESPONSE')));
      expect((await api.list(mine: true)).files.single.status, 'pending');
    },
  );
  test('new incompatible API versions fail closed', () async {
    final api = PublicResourceApi(
      owner: 'A',
      checkSession: () {},
      call: (_) async => {...response(), 'api_version': 2},
    );
    addTearDown(api.close);
    await expectLater(api.list(), throwsA(failure('UPDATE_REQUIRED')));
  });
  test('signed transfers reject plaintext, credentials and expiration', () {
    for (final change in [
      {'url': 'http://storage.test/file'},
      {'url': 'https://user:secret@storage.test/file'},
      {
        'headers': {'Authorization': 'Bearer user-session'},
      },
      {'expires_at': DateTime(2000).toIso8601String()},
      {'method': 'DELETE'},
    ]) {
      expect(
        () => ResourceTransfer.fromJson({...transfer('GET'), ...change}),
        throwsA(failure('INVALID_TRANSFER')),
      );
    }
  });
  for (final method in ['PUT', 'POST']) {
    test(
      '$method upload uses signed plan, sends no user JWT, final state comes from server',
      () async {
        final dir = await Directory.systemTemp.createTemp('resources-test-');
        addTearDown(() => dir.delete(recursive: true));
        final source = await File('${dir.path}/source').writeAsBytes(content);
        final task = DriveUpload(
          id: 'stable-upload',
          path: source.path,
          name: 'book.pdf',
          size: content.length,
          checksum: sha256.convert(content).toString(),
        );
        final actions = <String>[];
        final api = PublicResourceApi(
          owner: 'A',
          checkSession: () {},
          call: (body) async {
            expect(body['upload_id'], task.id);
            actions.add(body['action']);
            return {
              'api_version': 1,
              if (body['action'] == 'begin') 'transfer': transfer(method),
              if (body['action'] == 'complete')
                'file': fileJson(status: 'pending'),
            };
          },
          httpClient: MockClient((req) async {
            expect(req.method, method);
            expect(req.headers.containsKey('authorization'), isFalse);
            expect(req.headers.containsKey('apikey'), isFalse);
            expect(req.followRedirects, isFalse);
            if (method == 'PUT') {
              expect(req.bodyBytes, content);
            } else {
              expect(req.body, contains('name="file"'));
            }
            return http.Response('', 200);
          }),
        );
        addTearDown(api.close);
        expect((await api.upload(task, (_) {})).status, 'pending');
        expect(actions, ['begin', 'complete']);
        expect(await source.readAsBytes(), content);
      },
    );
  }
  test(
    'retry can finalize existing upload without uploading another object',
    () async {
      final dir = await Directory.systemTemp.createTemp('resources-test-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await File('${dir.path}/source').writeAsBytes(content);
      final task = DriveUpload(
        id: 'stable-upload',
        path: source.path,
        name: 'book.pdf',
        size: content.length,
        checksum: sha256.convert(content).toString(),
      );
      final api = PublicResourceApi(
        owner: 'A',
        checkSession: () {},
        call: (body) async => {
          'api_version': 1,
          'already_uploaded': true,
          'file': fileJson(),
        },
        httpClient: MockClient(
          (_) async => throw StateError('must not upload again'),
        ),
      );
      addTearDown(api.close);
      expect((await api.upload(task, (_) {})).published, isTrue);
    },
  );
  test(
    'download refreshes expired grant, checks bytes, does not require file ownership',
    () async {
      final dir = await Directory.systemTemp.createTemp('resources-test-');
      addTearDown(() => dir.delete(recursive: true));
      var grants = 0, gets = 0;
      final api = PublicResourceApi(
        owner: 'different-uploader',
        checkSession: () {},
        downloadDirectory: () async => dir,
        call: (body) async {
          expect(body['action'], 'download');
          grants++;
          return {
            'api_version': 1,
            'transfer': transfer('GET', host: 'another-provider.example.test'),
          };
        },
        httpClient: MockClient((req) async {
          gets++;
          return gets == 1
              ? http.Response('', 403)
              : http.Response.bytes(content, 200);
        }),
      );
      addTearDown(api.close);
      final file = PublicResource.fromJson(fileJson());
      final path = await api.download(file, (_) {});
      expect(await File(path).readAsBytes(), content);
      expect(grants, 2);
      await api.download(file, (_) {});
      expect(grants, 3);
      expect(gets, 2); // cached file still authorized remotely
    },
  );
  test(
    'corrupt downloads leave no usable file and session switches stop calls',
    () async {
      final dir = await Directory.systemTemp.createTemp('resources-test-');
      addTearDown(() => dir.delete(recursive: true));
      var signedIn = true;
      final api = PublicResourceApi(
        owner: 'A',
        checkSession: () {
          if (!signedIn) throw const DriveFailure('LOGIN_REQUIRED');
        },
        downloadDirectory: () async => dir,
        call: (_) async => {'api_version': 1, 'transfer': transfer('GET')},
        httpClient: MockClient(
          (_) async => http.Response.bytes([9, 9, 9, 9], 200),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.download(PublicResource.fromJson(fileJson()), (_) {}),
        throwsA(failure('CHECKSUM_FAILED')),
      );
      expect(
        (await dir.list(recursive: true).toList()).whereType<File>(),
        isEmpty,
      );
      signedIn = false;
      await expectLater(api.list(), throwsA(failure('LOGIN_REQUIRED')));
    },
  );

  Future<void> show(
    WidgetTester tester,
    FakeLibrary? fake, {
    bool english = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PublicResourcesPage(
          translate: (zh, en) => english ? en : zh,
          createApi: () => fake,
          settingsPage: const Scaffold(body: Text('Backup')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'closed and logged out pages have no upload, delete or private quota UI',
    (tester) async {
      final fake = FakeLibrary()..data = response(enabled: false);
      await show(tester, fake);
      expect(find.textContaining('公共资源正在准备中'), findsOneWidget);
      expect(find.text('上传资料'), findsNothing);
      expect(find.text('回收站'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await show(tester, null);
      expect(find.textContaining('正在建立游客身份'), findsOneWidget);
      expect(find.text('上传资料'), findsNothing);
    },
  );
  testWidgets(
    'public resource menu saves the selected reference to group files',
    (tester) async {
      final fake = FakeLibrary();
      PublicResource? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: PublicResourcesPage(
            translate: (zh, en) => zh,
            createApi: () => fake,
            settingsPage: const SizedBox(),
            onSaveToGroup: (file) async {
              selected = file;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('转存到群文件'));
      await tester.pumpAndSettle();
      expect(selected?.id, (fake.data['files'] as List).first['id']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'owner deletion requires confirmation and refreshes the reference list',
    (tester) async {
      final fake = FakeLibrary()
        ..data = response(
          files: [
            {...fileJson(), 'can_delete': true},
          ],
        );
      await show(tester, fake);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除我的文件'));
      await tester.pumpAndSettle();
      expect(fake.deleted, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(fake.deleted, isEmpty);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除我的文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(fake.deleted, ['resource-a']);
      expect(find.text('学修资料.pdf'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 412.0]) {
    for (final english in [false, true]) {
      testWidgets(
        'public resource controls fit $width english=$english and refresh switches',
        (tester) async {
          tester.view.physicalSize = Size(width, 760);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fake = FakeLibrary();
          await show(tester, fake, english: english);
          expect(tester.takeException(), isNull);
          expect(find.text(english ? 'Contribute' : '上传资料'), findsOneWidget);
          fake.data = response(upload: false, download: false, review: true);
          await tester.tap(find.byTooltip(english ? 'Refresh' : '刷新'));
          await tester.pumpAndSettle();
          expect(find.text(english ? 'Contribute' : '上传资料'), findsNothing);
          final download = tester.widget<IconButton>(
            find.byWidgetPredicate(
              (w) =>
                  w is IconButton &&
                  w.tooltip == (english ? 'Download and open' : '下载并打开'),
            ),
          );
          expect(download.onPressed, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'my contributions shows rejection, without delete or pending download',
    (tester) async {
      final fake = FakeLibrary()..mineFiles = [fileJson(status: 'rejected')];
      await show(tester, fake);
      await tester.tap(find.text('我的投稿'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请补充资料说明'), findsOneWidget);
      expect(find.byTooltip('下载并打开'), findsNothing);
      expect(find.text('删除'), findsNothing);
      await tester.enterText(find.byType(TextField), '经书');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(fake.queries.last, 'true|经书||time');
    },
  );
}
