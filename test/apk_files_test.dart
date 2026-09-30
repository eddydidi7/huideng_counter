import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:huideng_counter/services/apk_files.dart';
import 'package:huideng_counter/presentation/apk_file_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('apk-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test('APK classification and traversal-safe local filename', () {
    expect(isApk('新版.APK'), isTrue);
    expect(isApk('bad.apk.zip'), isFalse);
    expect(safeApkName('../../a.apk'), 'a.apk');
    expect(safeApkName(r'C:\files\a.apk'), 'a.apk');
  });
  test(
    'complete download verifies hash, reports progress, and reuses cache',
    () async {
      final bytes = [80, 75, 3, 4, 5, 6];
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response.bytes(bytes, 200);
      });
      final progress = <double>[];
      Future<String> download() => ApkFiles.download(
        owner: 'one',
        id: 'file',
        name: 'a.apk',
        size: bytes.length,
        checksum: sha256.convert(bytes).toString(),
        url: () async => 'https://example.test/a',
        guard: () {},
        progress: progress.add,
        transport: client,
      );
      final path = await download();
      expect(await File(path).readAsBytes(), bytes);
      expect(progress.last, 1);
      expect(await download(), path);
      expect(calls, 1);
      expect(await File('$path.json').exists(), isTrue);
      client.close();
    },
  );
  test(
    'interrupted download is not published as APK and retry succeeds',
    () async {
      var calls = 0;
      final client = MockClient(
        (_) async => http.Response.bytes(++calls == 1 ? [1] : [1, 2], 200),
      );
      Future<String> download() => ApkFiles.download(
        owner: 'one',
        id: 'retry',
        name: 'a.apk',
        size: 2,
        url: () async => 'https://example.test/a',
        guard: () {},
        progress: (_) {},
        transport: client,
      );
      await expectLater(download(), throwsStateError);
      expect(
        await (await ApkFiles.target('one', 'retry', 'a.apk')).exists(),
        isFalse,
      );
      expect(await File(await download()).readAsBytes(), [1, 2]);
      client.close();
    },
  );
  test(
    'size/hash mismatch and changed session never expose installable file',
    () async {
      final client = MockClient((_) async => http.Response.bytes([1, 2], 200));
      await expectLater(
        ApkFiles.download(
          owner: 'one',
          id: 'bad',
          name: 'a.apk',
          size: 2,
          checksum: sha256.convert([3, 4]).toString(),
          url: () async => 'https://example.test/a',
          guard: () {},
          progress: (_) {},
          transport: client,
        ),
        throwsStateError,
      );
      expect(
        await (await ApkFiles.target('one', 'bad', 'a.apk')).exists(),
        isFalse,
      );
      await expectLater(
        ApkFiles.download(
          owner: 'one',
          id: 'bad',
          name: 'a.apk',
          size: 2,
          url: () async => 'https://example.test/a',
          guard: () => throw StateError('account'),
          progress: (_) {},
          transport: client,
        ),
        throwsStateError,
      );
      expect(
        (await ApkFiles.target('one', 'bad', 'a.apk')).path,
        isNot((await ApkFiles.target('two', 'bad', 'a.apk')).path),
      );
      client.close();
    },
  );
  test(
    'checksum-addressed download resumes only a matching Content-Range',
    () async {
      final target = await ApkFiles.target('update', 'range', 'app.apk');
      await File('${target.path}.part').writeAsBytes([1, 2]);
      final client = MockClient((request) async {
        expect(request.headers['Range'], 'bytes=2-');
        return http.Response.bytes(
          [3, 4],
          206,
          headers: {'content-range': 'bytes 2-3/4'},
        );
      });
      final path = await ApkFiles.download(
        owner: 'update',
        id: 'range',
        name: 'app.apk',
        size: 4,
        checksum: sha256.convert([1, 2, 3, 4]).toString(),
        url: () async => 'https://example.test/a',
        guard: () {},
        progress: (_) {},
        transport: client,
      );
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      client.close();
    },
  );
  test('incorrect resume range never exposes an APK', () async {
    final target = await ApkFiles.target('update', 'bad-range', 'app.apk');
    await File('${target.path}.part').writeAsBytes([1]);
    final client = MockClient(
      (_) async => http.Response.bytes(
        [2],
        206,
        headers: {'content-range': 'bytes 0-0/2'},
      ),
    );
    await expectLater(
      ApkFiles.download(
        owner: 'update',
        id: 'bad-range',
        name: 'app.apk',
        size: 2,
        checksum: sha256.convert([1, 2]).toString(),
        url: () async => 'https://example.test/a',
        guard: () {},
        progress: (_) {},
        transport: client,
      ),
      throwsStateError,
    );
    expect(await target.exists(), false);
    client.close();
  });
  test(
    'network interruption retains verified-addressed partial and only requests remainder',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response.bytes([80, 75], 200);
        expect(request.headers['Range'], 'bytes=2-');
        return http.Response.bytes(
          [3, 4],
          206,
          headers: {'content-range': 'bytes 2-3/4'},
        );
      });
      Future<String> download() => ApkFiles.download(
        owner: 'app-update',
        id: 'interrupted',
        name: 'app.apk',
        size: 4,
        checksum: sha256.convert([80, 75, 3, 4]).toString(),
        url: () async => 'https://example.test/app.apk',
        guard: () {},
        progress: (_) {},
        transport: client,
        requireApk: true,
      );
      await expectLater(download(), throwsStateError);
      final path = await download();
      expect(await File(path).readAsBytes(), [80, 75, 3, 4]);
      expect(calls, 2);
      client.close();
    },
  );
  test(
    'HTML cannot be treated as APK even with matching size and hash',
    () async {
      final bytes = '<html>login</html>'.codeUnits;
      final client = MockClient(
        (_) async => http.Response.bytes(
          bytes,
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        ApkFiles.download(
          owner: 'app-update',
          id: 'html',
          name: 'app.apk',
          size: bytes.length,
          checksum: sha256.convert(bytes).toString(),
          url: () async => 'https://example.test/login',
          guard: () {},
          progress: (_) {},
          requireApk: true,
          transport: client,
        ),
        throwsStateError,
      );
      expect(
        await (await ApkFiles.target('app-update', 'html', 'app.apk')).exists(),
        false,
      );
      client.close();
    },
  );
  test('full verified partial is reused without any network request', () async {
    final bytes = [80, 75, 3, 4];
    final target = await ApkFiles.target(
      'app-update',
      'partial-complete',
      'app.apk',
    );
    await File('${target.path}.part').writeAsBytes(bytes);
    final client = MockClient(
      (_) async => throw StateError('Network must not be used'),
    );
    expect(
      await ApkFiles.download(
        owner: 'app-update',
        id: 'partial-complete',
        name: 'app.apk',
        size: bytes.length,
        checksum: sha256.convert(bytes).toString(),
        url: () async => 'https://example.test/app.apk',
        guard: () {},
        progress: (_) {},
        requireApk: true,
        transport: client,
      ),
      target.path,
    );
    client.close();
  });
  test(
    'update cache cleanup preserves unrelated APK shares and newer updates',
    () async {
      final client = MockClient(
        (_) async => http.Response.bytes([80, 75, 3, 4], 200),
      );
      Future<String> load(String owner, int version) => ApkFiles.download(
        owner: owner,
        id: '$version:hash',
        name: 'app.apk',
        size: 4,
        checksum: sha256.convert([80, 75, 3, 4]).toString(),
        url: () async => 'https://example.test/app.apk',
        guard: () {},
        progress: (_) {},
        transport: client,
      );
      final old = await load('app-update', 10);
      final newer = await load('app-update', 12);
      final shared = await load('personal', 10);
      await ApkFiles.cleanupUpdates(10);
      expect(await File(old).exists(), false);
      expect(await File(newer).exists(), true);
      expect(await File(shared).exists(), true);
      client.close();
    },
  );
  testWidgets('non Android card downloads but offers no install button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApkFileCard(
            name: 'a.apk',
            size: 2,
            guard: () {},
            load: (progress) async {
              progress(1);
              return '${directory.path}/a.apk';
            },
          ),
        ),
      ),
    );
    expect(find.textContaining('Android安装包'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('安装'), findsNothing);
    expect(find.text('已保存'), findsOneWidget);
    expect(find.text('保存 / 转发'), findsOneWidget);
  });
}
