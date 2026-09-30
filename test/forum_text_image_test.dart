import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/forum_text_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('automatic title keeps emoji intact and uses first line', () {
    expect(forumAutomaticTitle('  每日一善\n完整正文'), '每日一善');
    final text = List.filled(90, '🙏').join();
    expect(forumAutomaticTitle(text), text);
  });
  test(
    'short and long Chinese bodies produce decodable bounded PNG covers',
    () async {
      for (final body in ['每日一善，心怀慈悲。', List.filled(2000, '愿众生平安。').join()]) {
        final bytes = await renderForumTextImage(body);
        expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1080);
        expect(frame.image.height, 1440);
        expect(bytes.length, lessThan(10 * 1024 * 1024));
        frame.image.dispose();
        codec.dispose();
      }
    },
  );
}
