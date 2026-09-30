import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/note_reader.dart';
import 'package:huideng_counter/domain/reader_progress.dart';
import 'package:huideng_counter/services/windows_reader_speech.dart';

void main() {
  const scope = {'scope': 'test', 'noteId': 'note'};
  final calls = <MethodCall>[];
  var status = <String, dynamic>{'done': false, 'offset': 0};
  var voices = <Map<String, String>>[];
  late WindowsReaderSpeech speech;
  setUp(() {
    calls.clear();
    status = {'done': false, 'offset': 0};
    voices = [
      {'id': 'zh-real', 'name': 'Installed Chinese', 'language': 'zh-CN'},
      {'id': 'en-real', 'name': 'Installed English', 'language': 'en-US'},
    ];
    speech = WindowsReaderSpeech(
      automaticPolling: false,
      nativeCall: (method, args) async {
        calls.add(MethodCall(method, args));
        if (method == 'voices') return voices;
        if (method == 'status') return status;
        return true;
      },
    );
  });
  tearDown(() => speech.dispose());
  Future<void> start(String body, {int index = 0, int offset = 0}) async {
    await speech.invoke('start', {
      ...scope,
      'index': index,
      'offset': offset,
      'rate': 1.4,
    }, paragraphs: readerParagraphs(body));
  }

  test(
    'progress uses text lengths, supports 50/70 percent and surrogate boundaries',
    () {
      final p = ReaderProgress(readerParagraphs('${'甲' * 100}\n${'乙' * 900}'));
      expect(p.position(.5).index, 1);
      expect(p.position(.5).offset, 400);
      expect(p.position(.7).offset, 600);
      expect(p.fraction(1, 600 / 900), .7);
      final emoji = ReaderProgress(readerParagraphs('a😀b'));
      expect(emoji.position(.5).offset, 1);
    },
  );
  test(
    'real voice list, bounded segments, word progress and segment continuation',
    () async {
      expect(await speech.invoke('voices', null), voices);
      await start('中' * 2500, offset: 300);
      var spoken = calls.lastWhere((c) => c.method == 'speak').arguments as Map;
      expect(spoken['voice'], 'zh-real');
      expect((spoken['text'] as String).length, 900);
      status = {'done': false, 'offset': 15};
      expect((await speech.invoke('snapshot', scope))['offset'], 315);
      status = {'done': true};
      final next = await speech.invoke('snapshot', scope) as Map;
      expect(next['offset'], 1200);
      spoken = calls.lastWhere((c) => c.method == 'speak').arguments as Map;
      expect((spoken['text'] as String).length, 900);
    },
  );
  test('pause resume configure stop and route exit', () async {
    await start('中文正文');
    await speech.invoke('control', {...scope, 'action': 'pause'});
    expect((await speech.invoke('snapshot', scope))['playing'], false);
    await speech.invoke('control', {...scope, 'action': 'resume'});
    expect(calls.last.method, 'resume');
    await speech.invoke('control', {
      ...scope,
      'action': 'configure',
      'rate': 3.0,
      'voice': 'zh-real',
    });
    expect((calls.last.arguments as Map)['rate'], 3.0);
    await speech.invoke('exit', null);
    expect((await speech.invoke('snapshot', scope))['playing'], true);
    await speech.invoke('control', {...scope, 'action': 'stop'});
    expect((await speech.invoke('snapshot', scope))['active'], false);
  });
  test('missing Chinese and empty article produce explicit errors', () async {
    voices.removeAt(0);
    await expectLater(
      start('中文'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'NO_CHINESE_VOICE',
        ),
      ),
    );
    expect(
      (await speech.invoke('snapshot', scope))['error'],
      '当前Windows系统未安装可用的中文语音。',
    );
    await expectLater(
      start(''),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'EMPTY_TEXT'),
      ),
    );
    await speech.invoke('settings', null);
    expect(calls.last.method, 'settings');
  });
  test('restart at requested paragraph and finish without looping', () async {
    await start('first\nsecond', index: 1, offset: 3);
    expect((calls.last.arguments as Map)['text'], 'ond');
    status = {'done': true};
    final ended = await speech.invoke('snapshot', scope) as Map;
    expect(ended['active'], false);
    expect(ended['offset'], 6);
  });
  for (var step = 3; step <= 30; step++) {
    final rate = step / 10;
    test(
      'rate $rate follows native boundaries without estimating ahead',
      () async {
        await speech.invoke('start', {
          ...scope,
          'index': 0,
          'offset': 10,
          'rate': rate,
        }, paragraphs: readerParagraphs('中' * 120));
        status = {'done': false, 'started': false, 'offset': 0, 'length': 0};
        var snapshot = await speech.invoke('snapshot', scope) as Map;
        expect(snapshot['offset'], 10);
        expect(snapshot['rangeEnd'], 10);
        status = {'done': false, 'started': true, 'offset': 7, 'length': 2};
        snapshot = await speech.invoke('snapshot', scope) as Map;
        expect(snapshot['offset'], 17);
        expect(snapshot['rangeEnd'], 19);
        for (var poll = 0; poll < 5; poll++) {
          snapshot = await speech.invoke('snapshot', scope) as Map;
          expect(snapshot['offset'], 17);
          expect(snapshot['rangeEnd'], 19);
        }
        await speech.invoke('control', {
          ...scope,
          'action': 'configure',
          'rate': 3.3 - rate,
        });
        status = {'done': false, 'started': false, 'offset': 0, 'length': 0};
        snapshot = await speech.invoke('snapshot', scope) as Map;
        expect(snapshot['offset'], 17);
        expect(snapshot['rangeEnd'], 17);
      },
    );
  }
  test('speech offsets include embedded images only in visual layout', () {
    final paragraph = ReaderParagraph([
      {'insert': '前文'},
      {
        'insert': {'image': 'image'},
      },
      {'insert': '正文😀'},
    ]);
    expect(paragraph.text, '前文正文😀');
    expect(paragraph.layoutOffset(2), 3);
    expect(paragraph.layoutOffset(4), 5);
  });
}
