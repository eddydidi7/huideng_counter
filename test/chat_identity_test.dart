import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/chat_identity.dart';
import 'package:huideng_counter/services/group_operation_error.dart';

void main() {
  test('personal number never falls back to a private identifier', () {
    expect(personalNumberLabel({'personal_number': 1001}), '个人号：1001');
    expect(personalNumberLabel({'personal_number': '10001'}), '个人号：10001');
    expect(personalNumberLabel({'user_id': 'internal-uuid', 'device_id': 'device'}), '个人号：未设置');
    expect(personalNumberLabel({'personal_number': 'internal-uuid'}), '个人号：未设置');
  });
  test('group failures distinguish permission, capacity, identity and network', () {
    expect(groupOperationError(Exception('42501 CHAT_MANAGER_REQUIRED')), contains('管理'));
    expect(groupOperationError(Exception('CHAT_GROUP_SIZE')), contains('人数上限'));
    expect(groupOperationError(Exception('CHAT_INVALID_USER')), contains('账号不可用'));
    expect(groupOperationError(TimeoutException('timeout')), contains('网络'));
    expect(groupOperationError(Exception('PGRST202')), contains('尚未更新'));
  });
}
