import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/chat_qr.dart';

void main() {
  const id = '00000000-0000-4000-8000-000000000001';
  test('Personal and group QR roundtrip', () {
    for (final kind in ['contact', 'group']) {
      final result = ChatQr.parse(ChatQr(kind, id).value)!;
      expect(result.kind, kind);
      expect(result.id, id);
    }
  });
  test('Only versioned app QR accepted, never arbitrary links', () {
    for (final text in [
      'https://evil.test',
      'huideng://chat/group/$id',
      'huideng://chat/group/$id?v=2',
      'huideng://chat/group/$id?v=1#evil',
      'huideng://chat/group/../../../file?v=1',
      'huideng://admin@chat/group/$id?v=1',
      'huideng://chat:443/group/$id?v=1',
      'huideng://chat/admin/$id?v=1',
      'huideng://chat/group/not-a-token?v=1',
    ]) {
      expect(ChatQr.parse(text), isNull, reason: text);
    }
  });
}
