import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/data/remote/resource_resumable_upload.dart';
import 'package:huideng_counter/domain/cloud_file.dart';
import 'package:huideng_counter/data/remote/public_resource_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'uploaded APK retries verification without retransmitting or publishing early',
    () async {
      final temp = await Directory.systemTemp.createTemp('tus-verify');
      addTearDown(() => temp.delete(recursive: true));
      final file = await File('${temp.path}/a.apk').writeAsBytes([1, 2, 3]);
      final hash = sha256.convert([1, 2, 3]).toString();
      final task = DriveUpload(
        id: 'id',
        path: file.path,
        name: 'a.apk',
        size: 3,
        checksum: hash,
      );
      var steps = 0;
      final progress = <double>[];
      final api = PublicResourceApi(
        owner: 'u',
        checkSession: () {},
        httpClient: MockClient(
          (_) async => throw StateError('must not upload again'),
        ),
        call: (body) async {
          expect(body['upload_protocol'], 'tus');
          if (body['action'] == 'begin') {
            return {
              'api_version': 1,
              'resumable': {'stored': true},
            };
          }
          if (++steps == 1) {
            return {
              'api_version': 1,
              'verifying': true,
              'verified_bytes': 2,
              'total_bytes': 3,
            };
          }
          return {
            'api_version': 1,
            'file': {
              'id': 'id',
              'file_name': 'a.apk',
              'file_size': 3,
              'checksum': hash,
              'status': 'published',
            },
          };
        },
      );
      addTearDown(api.close);
      final result = await api.upload(task, progress.add);
      expect(result.published, true);
      expect(steps, 2);
      expect(progress.last, 1);
    },
  );
  test(
    'TUS resumes after lost PATCH response and process restart, preserves APK type',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('tus-test');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/test.apk');
      const chunk = 6291456;
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(chunk * 2 + 13);
      await handle.close();
      final task = DriveUpload(
        id: 'test-upload',
        path: file.path,
        name: 'test.apk',
        size: chunk * 2 + 13,
        checksum: 'testhash',
      );
      final plan = {
        'url':
            'https://project.storage.supabase.co/storage/v1/upload/resumable',
        'token': 'scoped-token',
        'bucket': 'public-resources',
        'object_name': 'resources/u/test.apk',
        'content_type': 'application/vnd.android.package-archive',
        'chunk_size': chunk,
      };
      int offset = 0, posts = 0, patches = 0;
      bool disconnected = true;
      final client = MockClient((req) async {
        expect(req.headers['x-signature'], 'scoped-token');
        expect(req.headers.containsKey('authorization'), false);
        if (req.method == 'POST') {
          posts++;
          expect(req.url.path, '/storage/v1/upload/resumable/sign');
          expect(req.headers['upload-length'], '${task.size}');
          expect(req.headers['upload-metadata'], contains('contentType'));
          return http.Response(
            '',
            201,
            headers: {'location': '${plan['url']}/sign/session'},
          );
        }
        if (req.method == 'HEAD') {
          if (disconnected) throw const SocketException('offline');
          return http.Response('', 200, headers: {'upload-offset': '$offset'});
        }
        expect(req.method, 'PATCH');
        expect(req.bodyBytes.length, lessThanOrEqualTo(chunk));
        expect(int.parse(req.headers['upload-offset']!), offset);
        patches++;
        offset += req.bodyBytes.length;
        if (disconnected) throw const SocketException('response lost');
        return http.Response('', 204, headers: {'upload-offset': '$offset'});
      });
      Future<void> upload() => uploadResourceResumable(
        client: client,
        source: file,
        task: task,
        owner: 'u',
        plan: plan,
        guard: () {},
        progress: (_) {},
      );
      await expectLater(
        upload(),
        throwsA(
          isA<DriveFailure>().having((e) => e.code, 'code', 'NETWORK_FAILED'),
        ),
      );
      expect(offset, chunk);
      disconnected = false;
      await upload();
      expect(offset, task.size);
      expect(posts, 1);
      expect(patches, 3);
      await upload();
      expect(patches, 3);
      expect((await SharedPreferences.getInstance()).getKeys(), hasLength(1));
    },
  );
  test('TUS rejects cross-host upload location before sending file', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient(
      (req) async => http.Response(
        '',
        201,
        headers: {
          'location': 'https://elsewhere.test/storage/v1/upload/resumable/id',
        },
      ),
    );
    await expectLater(
      uploadResourceResumable(
        client: client,
        source: File('unused'),
        task: DriveUpload(
          id: 'a',
          path: 'unused',
          name: 'a.apk',
          size: 1,
          checksum: 'x',
        ),
        owner: 'u',
        plan: {
          'url':
              'https://project.storage.supabase.co/storage/v1/upload/resumable',
          'token': 'token',
          'bucket': 'public-resources',
          'object_name': 'a.apk',
          'content_type': 'application/vnd.android.package-archive',
          'chunk_size': 6291456,
        },
        guard: () {},
        progress: (_) {},
      ),
      throwsA(isA<DriveFailure>()),
    );
  });
}
