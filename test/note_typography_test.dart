import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huideng_counter/presentation/note_typography_page.dart';
import 'package:huideng_counter/presentation/note_reader_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy sizes use the new bounds and integer steps', () async {
    for (final entry in {8.0: 10.0, 60.0: 40.0, 23.6: 24.0}.entries) {
      final scope = 'legacy-size-${entry.key}';
      SharedPreferences.setMockInitialValues({
        'reader.preferences.v1.$scope': jsonEncode({'size': entry.key}),
      });
      final settings = NoteTypography.forScope(scope);
      await settings.ready;
      expect(settings.size, entry.value);
      await settings.save();
      await settings.reload();
      expect(settings.size, entry.value);
    }
    expect(NoteTypography.normalizeSize(null), 20);
    expect(NoteTypography.normalizeSize(double.nan), 20);
    expect(NoteTypography.sizeDivisions, 30);
  });

  testWidgets('typography slider updates preview and saves in unit steps', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const scope = 'slider-unit-step';
    await tester.pumpWidget(
      const MaterialApp(home: NoteTypographyPage(scope: scope)),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    expect(slider.min, 10);
    expect(slider.max, 40);
    expect(slider.divisions, 30);
    expect(slider.value, 20);
    slider.onChanged!(31);
    await tester.pumpAndSettle();
    final preview = tester.widget<Text>(
      find.text('愿以清净心，安住当下。\nRead slowly and clearly.'),
    );
    expect(preview.style!.fontSize, 31);
    await NoteTypography.forScope(scope).reload();
    expect(NoteTypography.forScope(scope).size, 31);
  });
  test(
    'font endpoints persist and reload without changing spacing or TTS',
    () async {
      const scope = 'typography-persistence';
      SharedPreferences.setMockInitialValues({
        'reader.preferences.v1.$scope': jsonEncode({
          'rate': 1.7,
          'line': 1.8,
          'paragraph': 9,
        }),
      });
      final settings = NoteTypography.forScope(scope);
      await settings.ready;
      expect(settings.size, 20);
      for (final size in [10.0, 40.0]) {
        settings.size = size;
        await settings.save();
        settings.size = 22;
        await settings.reload();
        expect(settings.size, size);
        expect(settings.line, 1.8);
        expect(settings.paragraph, 9);
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString(settings.key)!)['rate'], 1.7);
      }
      expect(
        (NoteTypography.textHeight(40, 2.05) - 1) * 40,
        closeTo((NoteTypography.textHeight(22, 2.05) - 1) * 22, .001),
      );
    },
  );

  for (final width in [360.0, 1440.0]) {
    for (final size in [10.0, 40.0]) {
      testWidgets('reader restores $size at width $width without overflow', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'reader.preferences.v1.font-test': jsonEncode({'size': size}),
        });
        const native = MethodChannel('org.huideng.counter/reader');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          (_) async => null,
        );
        const body = '正文在大字号下正常换行，保留上下文。';
        final prepared = await PreparedNoteReader.load(body);
        await tester.pumpWidget(
          MaterialApp(
            home: NoteReaderPage(
              body: body,
              noteId: 'article',
              scope: 'font-test',
              title: '资料',
              storedNote: false,
              prepared: prepared,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = tester.widget<Text>(
          find.byKey(const ValueKey('reader-paragraph-0')),
        );
        expect(text.style!.fontSize, size);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        );
      });
    }
  }
}
