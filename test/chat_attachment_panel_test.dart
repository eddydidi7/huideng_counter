import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/presentation/chat_attachment_panel.dart';
void main() {
  for(final width in [320.0,360.0,412.0]) {
    testWidgets('attachment grid actions at $width', (tester) async {
      tester.view.physicalSize=Size(width,640);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:Align(alignment:Alignment.bottomCenter,child:ChatAttachmentPanel(english:false,onSelected:(s)=>selected=s)))));
      await tester.tap(find.text('音乐'));expect(selected,'music');
      await tester.tap(find.text('位置'));expect(selected,'location');
      expect(find.text('视频通话'),findsOneWidget);
      expect(find.text('语音输入'),findsOneWidget);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
