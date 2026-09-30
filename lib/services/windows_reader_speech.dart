import 'dart:async';
import 'package:flutter/services.dart';
import '../domain/note_reader.dart';

typedef ReaderNativeCall =
    Future<dynamic> Function(String method, dynamic arguments);

/// Owns the Windows session independently of reader focus and route lifetime.
/// The native engine receives only one shared readerSpeechEnd segment at a time.
class WindowsReaderSpeech {
  WindowsReaderSpeech({
    ReaderNativeCall? nativeCall,
    this.automaticPolling = true,
  }) : nativeCall = nativeCall ?? _invoke;
  static final instance = WindowsReaderSpeech();
  static const channel = MethodChannel('org.huideng.counter/windows_tts');
  static Future<dynamic> _invoke(String method, dynamic args) =>
      channel.invokeMethod(method, args);
  final ReaderNativeCall nativeCall;
  final bool automaticPolling;
  List<ReaderParagraph> _paragraphs = [];
  List<Map<String, dynamic>> _voices = [];
  String _scope = '', _note = '', _language = 'auto', _voice = '', _error = '';
  int _index = 0, _offset = 0, _start = 0, _end = 0;
  int _rangeEnd = 0;
  double _rate = 1;
  bool _active = false, _playing = false, _repeat = false, _needsSpeak = true;
  Timer? _timer;
  Future<void> _tail = Future.value();

  static String errorText(Object e) {
    if (e is PlatformException) {
      return switch (e.code) {
        'NO_CHINESE_VOICE' => '当前Windows系统未安装可用的中文语音。',
        'NO_VOICE' => '当前Windows系统没有可用的所选语言语音，请打开Windows语音设置。',
        'EMPTY_TEXT' => '当前笔记没有可朗读的正文。',
        'TTS_INIT_FAILED' => 'Windows语音初始化失败，请检查系统语音设置。',
        'SETTINGS_FAILED' => '无法打开Windows语音设置，请在系统设置中打开“时间和语言 → 语音”。',
        _ => 'Windows系统语音不可用或朗读失败，请检查语音设置后重试。',
      };
    }
    return 'Windows朗读暂不可用，请检查系统语音设置后重试。';
  }

  Future<dynamic> invoke(
    String method,
    dynamic arguments, {
    List<ReaderParagraph>? paragraphs,
  }) {
    final next = _tail.then((_) async {
      try {
        return await _handle(
          method,
          arguments is Map ? arguments : const {},
          paragraphs,
        );
      } catch (e) {
        _error = errorText(e);
        _playing = false;
        _needsSpeak = true;
        _timer?.cancel();
        try {
          await nativeCall('stop', null);
        } catch (_) {}
        rethrow;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<dynamic> _handle(
    String method,
    Map args,
    List<ReaderParagraph>? paragraphs,
  ) async {
    if (method == 'brightness' || method == 'exit') return true;
    if (method == 'settings' || method == 'install') {
      return nativeCall('settings', null);
    }
    if (method == 'voices') {
      _voices = [
        for (final v in await nativeCall('voices', null) as List)
          Map<String, dynamic>.from(v as Map),
      ];
      return _voices;
    }
    if (method == 'start') {
      await nativeCall('stop', null);
      _paragraphs = paragraphs ?? [];
      if (!_paragraphs.any((p) => p.text.trim().isNotEmpty)) {
        throw PlatformException(code: 'EMPTY_TEXT');
      }
      _scope = args['scope'] as String;
      _note = args['noteId'] as String;
      _index = (args['index'] as int).clamp(0, _paragraphs.length - 1);
      _offset = (args['offset'] as int).clamp(
        0,
        _paragraphs[_index].text.length,
      );
      _configure(args);
      await _handle('voices', const {}, null);
      _active = _playing = true;
      _error = '';
      await _speak();
      _poll();
      return true;
    }
    if (args['scope'] != _scope || args['noteId'] != _note) {
      return <String, dynamic>{};
    }
    if (method == 'snapshot') {
      await _update();
      return {
        'active': _active,
        'playing': _playing,
        'index': _index,
        'offset': _offset,
        'rangeEnd': _rangeEnd,
        'rate': _rate,
        'error': _error,
      };
    }
    if (method == 'control') {
      await _update();
      switch (args['action']) {
        case 'stop':
          await nativeCall('stop', null);
          _active = _playing = false;
          _needsSpeak = true;
          _timer?.cancel();
        case 'pause':
          if (_playing) await nativeCall('pause', null);
          _playing = false;
        case 'resume':
          _error = '';
          _active = _playing = true;
          if (_needsSpeak) {
            await _speak();
          } else {
            await nativeCall('resume', null);
          }
          _poll();
        case 'next' || 'previous':
          await nativeCall('stop', null);
          _index = (_index + (args['action'] == 'next' ? 1 : -1)).clamp(
            0,
            _paragraphs.length - 1,
          );
          _offset = 0;
          _needsSpeak = true;
          if (_playing) await _speak();
        case 'configure':
          _configure(args);
          await nativeCall('stop', null);
          _needsSpeak = true;
          if (_playing) await _speak();
      }
      return true;
    }
    return null;
  }

  void _configure(Map args) {
    _rate = normalizeReaderRate((args['rate'] as num? ?? _rate).toDouble());
    _repeat = args['repeat'] as bool? ?? _repeat;
    _language = args['language'] as String? ?? _language;
    _voice = args['voice'] as String? ?? _voice;
  }

  void _poll() {
    _timer?.cancel();
    if (automaticPolling && _active) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        unawaited(
          invoke('snapshot', {
            'scope': _scope,
            'noteId': _note,
          }).catchError((Object _) => <String, dynamic>{}),
        );
      });
    }
  }

  Future<void> _update() async {
    if (!_playing || _needsSpeak) return;
    final status = await nativeCall('status', null) as Map;
    if (status['done'] == true) {
      _offset = _end;
      await _speak();
    } else {
      _offset = (_start + (status['offset'] as num? ?? 0).toInt()).clamp(
        _start,
        _end,
      );
      _rangeEnd = status['started'] == false
          ? _offset
          : (_offset + (status['length'] as num? ?? 1).toInt()).clamp(
              _offset,
              _end,
            );
    }
  }

  Future<void> _speak() async {
    for (var skipped = 0; skipped <= _paragraphs.length; skipped++) {
      if (_index >= _paragraphs.length) {
        if (_repeat) {
          _index = 0;
          _offset = 0;
        } else {
          _index = _paragraphs.length - 1;
          _offset = _paragraphs.last.text.length;
          _active = _playing = false;
          _timer?.cancel();
          return;
        }
      }
      final text = _paragraphs[_index].text;
      if (text.trim().isEmpty || _offset >= text.length) {
        _index++;
        _offset = 0;
        continue;
      }
      _start = _offset;
      _rangeEnd = _offset;
      _end = readerSpeechEnd(text, _start);
      final desired = _language == 'auto'
          ? (RegExp(r'[\u3400-\u9fff]').hasMatch(text.substring(_start, _end))
                ? 'zh'
                : 'en')
          : _language;
      final selected = _voices.where((v) => v['id'] == _voice).firstOrNull;
      final available = selected != null
          ? [selected]
          : _voices
                .where(
                  (v) => (v['language'] as String? ?? '')
                      .toLowerCase()
                      .startsWith(desired),
                )
                .toList();
      if (available.isEmpty) {
        throw PlatformException(
          code: desired == 'zh' ? 'NO_CHINESE_VOICE' : 'NO_VOICE',
        );
      }
      final voice =
          available.where((v) => v['id'] == _voice).firstOrNull ??
          available.first;
      await nativeCall('speak', {
        'text': text.substring(_start, _end),
        'voice': voice['id'],
        'rate': _rate,
      });
      _needsSpeak = false;
      return;
    }
    throw PlatformException(code: 'EMPTY_TEXT');
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _tail;
    await nativeCall('stop', null);
    _active = _playing = false;
  }
}
