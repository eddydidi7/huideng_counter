import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/core/app_controller.dart';
import 'package:huideng_counter/domain/models.dart';
import 'package:huideng_counter/presentation/windows_display.dart';

class DisplaySettingsRepository extends Fake implements CounterRepository {
  final values = <String, String>{};
  @override
  Future<Map<String, String>> settings() async => Map.of(values);
  @override
  Future<List<CounterProject>> projects() async => [];
  @override
  Future<void> saveSetting(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  testWidgets(
    'display preference defaults to large and survives controller reload',
    (tester) async {
      final repository = DisplaySettingsRepository();
      final app = AppController(repository);
      expect(app.windowsDisplaySize, 'large');
      await app.set('windowsDisplaySize', 'extraLarge');
      app.dispose();
      final reopened = AppController(repository);
      await reopened.reload();
      expect(reopened.windowsDisplaySize, 'extraLarge');
      reopened.dispose();
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final size in windowsDisplaySizes) {
      testWidgets(
        '$platform $size scales content without scaling whitespace or DPI twice',
        (tester) async {
          late BuildContext ui, content, reader;
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(1280, 800),
                  devicePixelRatio: 2,
                  textScaler: TextScaler.linear(1.25),
                ),
                child: WindowsDisplay(
                  size: size,
                  child: Scaffold(
                    body: Column(
                      children: [
                        Builder(
                          builder: (c) {
                            ui = c;
                            return const Padding(
                              key: ValueKey('padding'),
                              padding: EdgeInsets.all(12),
                              child: Icon(Icons.folder),
                            );
                          },
                        ),
                        WindowsContentText(
                          child: Builder(
                            builder: (c) {
                              content = c;
                              return const Text(
                                '笔记正文与共享资料',
                                style: TextStyle(fontSize: 18),
                              );
                            },
                          ),
                        ),
                        WindowsContentText(
                          independentSize: true,
                          child: Builder(
                            builder: (c) {
                              reader = c;
                              return const Text(
                                '独立阅读字号',
                                style: TextStyle(fontSize: 26),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          final windows = platform == TargetPlatform.windows;
          final factor = windows ? windowsTextFactor(size) : 1.0;
          expect(
            MediaQuery.textScalerOf(ui).scale(18),
            closeTo(18 * 1.25 * factor, .001),
          );
          expect(
            MediaQuery.textScalerOf(content).scale(18),
            closeTo(18 * 1.25 * factor * (windows ? 1.1 : 1), .001),
          );
          expect(
            MediaQuery.textScalerOf(reader).scale(26),
            closeTo(26 * 1.25, .001),
          );
          expect(MediaQuery.devicePixelRatioOf(ui), 2);
          expect(
            tester
                .widget<Padding>(find.byKey(const ValueKey('padding')))
                .padding,
            const EdgeInsets.all(12),
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  for (final width in [640.0, 1440.0, 2560.0]) {
    for (final dpi in [1.0, 2.0]) {
      testWidgets(
        'large window $width DPI $dpi uses the available reading width',
        (tester) async {
          tester.view.physicalSize = Size(width * dpi, 900 * dpi);
          tester.view.devicePixelRatio = dpi;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              builder: (c, child) =>
                  WindowsDisplay(size: 'extraLarge', child: child!),
              home: Scaffold(
                appBar: AppBar(title: const Text('笔记')),
                body: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: readingPageMaxWidth(760),
                    ),
                    child: ListView(
                      key: const ValueKey('reading'),
                      children: [
                        WindowsContentText(
                          child: Text(
                            '正文内容。' * 100,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('reading'))).width,
            width,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }
}
