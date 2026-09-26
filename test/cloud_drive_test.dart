import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/domain/cloud_file.dart';
import 'package:huideng_counter/data/local/drive_upload_queue.dart';
import 'package:huideng_counter/data/remote/oss_v4.dart';

StorageCredential credential(Duration lifetime) => StorageCredential({
  'provider': 'aliyun_oss',
  'accessKeyId': 'STS.test',
  'accessKeySecret': 'temporary-test-only',
  'securityToken': 'test-token',
  'bucket': 'private-bucket',
  'region': 'oss-cn-hongkong',
  'endpoint': 'https://private-bucket.oss-cn-hongkong.aliyuncs.com',
  'expiresAt': DateTime.now().add(lifetime).toIso8601String(),
  'userPrefix': 'users/test/',
  'objectKey': 'users/test/cloud/test',
});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queue survives restart, keeps UUID and isolates accounts', () async {
    SharedPreferences.setMockInitialValues({});
    final task = DriveUpload(
      id: 'stable-id',
      path: '/source',
      name: '经论.pdf',
      size: 100,
      checksum: 'checksum',
      state: 'uploading',
    );
    await DriveUploadQueue('A').save([task]);
    expect(await DriveUploadQueue('B').read(), isEmpty);
    final reopened = await DriveUploadQueue('A').read();
    expect(reopened.single.id, 'stable-id');
    expect(reopened.single.state, 'failed');
    await DriveUploadQueue('A').save(reopened);
    expect((await DriveUploadQueue('A').read()).length, 1);
  });
  test('temporary credential refresh window and redaction', () {
    expect(credential(const Duration(minutes: 15)).fresh, isTrue);
    expect(credential(const Duration(minutes: 4)).fresh, isFalse);
    expect(credential(const Duration(minutes: -1)).fresh, isFalse);
    expect(
      credential(const Duration(minutes: 15)).toString(),
      isNot(contains('temporary-test-only')),
    );
  });
  test('Dart and Edge OSS V4 signature agree for deterministic fixture', () {
    final headers = ossReadHeaders(
      credential(const Duration(minutes: 15)),
      now: DateTime.parse('2026-09-17T01:02:03Z'),
    );
    expect(headers['x-oss-date'], '20260917T010203Z');
    expect(
      headers['Authorization'],
      'OSS4-HMAC-SHA256 Credential=STS.test/20260917/cn-hongkong/oss/aliyun_v4_request,Signature=419b3dc1ec5bab5a574256fca4323e4aec988d783aa22978a3643b2df679eab9',
    );
  });
}
