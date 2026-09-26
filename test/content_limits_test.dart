import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/content_limits.dart';

void main() {
  test('article limit counts Unicode code points consistently', () {
    expect(articleContentCharacterCount('中a🙂\n'), 4);
    final atLimit = List.filled(maxArticleContentCharacters, '中').join();
    expect(isArticleContentWithinLimit(atLimit), isTrue);
    expect(
      isArticleContentWithinLimit('${atLimit}中'),
      isFalse,
    );
  });
}
