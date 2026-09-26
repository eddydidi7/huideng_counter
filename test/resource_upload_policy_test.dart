import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/resource_upload_policy.dart';

void main() {
  test(
    'quota failures explain preservation and never suggest deleting user data',
    () {
      expect(
        resourceLimitMessage(StateError('RESOURCE_USER_QUOTA')),
        contains('已有文件不会被删除'),
      );
      expect(
        resourceLimitMessage(StateError('RESOURCE_DAILY_LIMIT')),
        contains('明天'),
      );
      expect(
        resourceLimitMessage(StateError('RESOURCE_MONTHLY_LIMIT')),
        contains('下月'),
      );
      expect(resourceLimitMessage(StateError('other')), isNull);
    },
  );
}
