import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:huideng_counter/data/remote/public_resource_api.dart';
import 'package:huideng_counter/domain/public_resource.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'preview caches transformed bytes but reauthorizes cached access',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'resource-preview-test',
      );
      addTearDown(() => dir.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => dir.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            ),
      );
      var calls = 0, downloads = 0;
      var enabled = true;
      final api = PublicResourceApi(
        owner: 'u',
        checkSession: () {},
        call: (input) async {
          calls++;
          expect(input['action'], 'preview');
          return {
            'api_version': 1,
            if (!enabled) 'error': 'DOWNLOAD_DISABLED',
            'url': 'https://example.test/storage/v1/render/image/sign/a',
          };
        },
        httpClient: MockClient((request) async {
          downloads++;
          expect(request.url.path, contains('/render/image/'));
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/webp'},
          );
        }),
      );
      addTearDown(api.close);
      final file = PublicResource.fromJson({
        'id': 'id',
        'file_name': 'image.png',
        'file_size': 9000000,
        'checksum': 'a' * 64,
        'status': 'published',
      });
      expect(await (await api.preview(file)).length(), 3);
      expect(await (await api.preview(file)).length(), 3);
      expect(calls, 2);
      expect(downloads, 1);
      enabled = false;
      await expectLater(api.preview(file), throwsA(anything));
      expect(downloads, 1);
    },
  );
}
