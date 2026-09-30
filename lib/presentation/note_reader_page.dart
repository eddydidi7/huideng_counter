import 'adaptive_action_bar.dart';
import '../core/app_controller.dart';
import 'note_share_actions.dart';
import 'note_tools.dart';
import 'note_typography_page.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'note_rich_content.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'windows_display.dart';
import '../domain/note_reader.dart';
import '../domain/reader_progress.dart';
import '../services/windows_reader_speech.dart';
import 'routed_image.dart';

class PreparedNoteReader {
  PreparedNoteReader(this.paragraphs, this.preferences);
  final List<ReaderParagraph> paragraphs;
  final SharedPreferences preferences;

  static Future<PreparedNoteReader> load(String body) async {
    final paragraphs = body.length < 100000
        ? readerParagraphs(body)
        : await compute(readerParagraphs, body);
    return PreparedNoteReader(
      paragraphs,
      await SharedPreferences.getInstance(),
    );
  }
}

/// Keep the editor mounted and visible until the reader can paint its content.
Future<void> openNoteReader(
  BuildContext context, {
  required String body,
  required String noteId,
  required String scope,
  required String title,
  required int? documentOffset,
  AppController? app,
  bool storedNote = true,
}) async {
  final prepared = await PreparedNoteReader.load(body);
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => NoteReaderPage(
        body: body,
        noteId: noteId,
        scope: scope,
        title: title,
        app: app,
        storedNote: storedNote,
        prepared: prepared,
        documentOffset: documentOffset,
      ),
    ),
  );
}

/// Takes a snapshot only; deliberately has no NotesRepository or save callback.
class NoteReaderPage extends StatefulWidget {
  const NoteReaderPage({
    super.key,
    required this.body,
    required this.noteId,
    required this.scope,
    required this.title,
    this.app,
    this.storedNote = true,
    this.prepared,
    this.documentOffset,
  });
  final String body, noteId, scope, title;
  final AppController? app;
  final bool storedNote;
  final PreparedNoteReader? prepared;
  final int? documentOffset;
  @override
  State<NoteReaderPage> createState() => _NoteReaderPageState();
}

class _NoteReaderPageState extends State<NoteReaderPage>
    with WidgetsBindingObserver {
  static const native = MethodChannel('org.huideng.counter/reader');
  List<ReaderParagraph> paragraphs = [];
  late ReaderProgress progress;
  bool get windows => defaultTargetPlatform == TargetPlatform.windows;
  List<Map<String, dynamic>> voices = [];
  String voice = '';
  double? draggingProgress;
  bool seeking = false, followScroll = false, readingMoved = true;
  bool resumeAfterSeek = false;
  Future<void> seekPause = Future.value();
  final keys = <int, GlobalKey>{};
  final centerKey = GlobalKey();
  int viewportAnchor = 0;
  Timer? sessionPoll;
  Timer? resumeFollow;
  bool pollingSession = false, manualScroll = false;
  int followGeneration = 0, speechRangeEnd = 0;
  String? speechPath;
  bool sessionActive = false, restoredSession = false;
  bool exiting = false, nativeExited = false;
  late final scroll = _ReaderScrollController(initialPixels);
  int? initialParagraphOffset;
  SharedPreferences? prefs;
  Timer? debounce;
  bool controls = false,
      settingsOpen = false,
      locked = true,
      repeat = false,
      playing = false,
      loading = true,
      starting = false,
      leaving = false;
  double fontSize = NoteTypography.defaultSize,
      brightness = .65,
      lineHeight = 2.05,
      paragraphSpacing = 10,
      spacing = 0,
      rate = 1;
  String theme = 'dark', font = 'system', language = 'auto';
  int reading = 0,
      speaking = 0,
      speechOffset = 0,
      utteranceStart = 0,
      utteranceEnd = 0,
      sequence = 0;
  double paragraphFraction = 0;
  String? activeId, error;
  Future<void> writes = Future.value();
  String get settingsKey => 'reader.preferences.v1.${widget.scope}';
  String get positionKey =>
      'reader.position.v1.${widget.scope}.${widget.noteId}';
  Color get background => theme == 'paper'
      ? const Color(0xfff1e7ce)
      : theme == 'light'
      ? const Color(0xfff6f6f4)
      : const Color(0xff101214);
  Color get foreground =>
      theme == 'dark' ? const Color(0xffdfddd5) : const Color(0xff262822);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(onScroll);

    init();
  }

  double bounded(dynamic v, double fallback, double low, double high) =>
      v is num && v.isFinite ? v.toDouble().clamp(low, high) : fallback;
  Future<void> init() async {
    try {
      final prepared =
          widget.prepared ?? await PreparedNoteReader.load(widget.body);
      paragraphs = prepared.paragraphs;
      prefs = prepared.preferences;
      final s = jsonDecode(prefs!.getString(settingsKey) ?? '{}') as Map;
      fontSize = NoteTypography.normalizeSize(s['size']);
      brightness = bounded(s['brightness'], .65, .05, 1);
      lineHeight = bounded(s['line'], 2.05, 1.2, 2.6);
      paragraphSpacing = bounded(s['paragraph'], 10, 0, 32);
      spacing = bounded(s['spacing'], 0, -.5, 2);
      rate = normalizeReaderRate(bounded(s['rate'], 1, .3, 3));
      repeat = s['repeat'] == true;
      voice = s['voice'] as String? ?? '';
      locked = s['locked'] != false;
      theme = ['dark', 'paper', 'light'].contains(s['theme'])
          ? s['theme']
          : 'dark';
      font = s['font'] == 'source' ? 'source' : 'system';
      language = ['auto', 'zh', 'en'].contains(s['language'])
          ? s['language']
          : 'auto';
      final p = jsonDecode(prefs!.getString(positionKey) ?? '{}') as Map;
      reading = restoreReaderAnchor(paragraphs, p['read']);
      speaking = restoreReaderAnchor(paragraphs, p['speech']);
      paragraphFraction = bounded(p['fraction'], 0, 0, .99);
      if (p['speech'] is Map &&
          p['speech']['anchor'] == paragraphs[speaking].anchor) {
        speechOffset = (p['speech']['offset'] as num? ?? 0).toInt().clamp(
          0,
          paragraphs[speaking].text.length,
        );
      }
    } catch (_) {
      error = '阅读设置未能恢复，正文仍可阅读。';
    }
    if (!mounted) return;
    if (paragraphs.isEmpty) paragraphs = [ReaderParagraph([])];
    progress = ReaderProgress(paragraphs);
    if (widget.documentOffset != null) {
      var remaining = widget.documentOffset!;
      reading = 0;
      for (var i = 0; i < paragraphs.length; i++) {
        reading = i;
        final length =
            paragraphs[i].runs.fold<int>(
              0,
              (sum, run) =>
                  sum +
                  (run['insert'] is String
                      ? (run['insert'] as String).length
                      : 1),
            ) +
            (widget.body.length < 100000 ? 1 : 0);
        if (remaining < length) break;
        remaining -= length;
      }
      initialParagraphOffset = remaining;
      paragraphFraction = 0;
    }
    viewportAnchor = reading;
    // Prepared entries reach this synchronously, before their first build.
    loading = false;
    if (widget.prepared == null) setState(() {});
    unawaited(initSpeech());
    // Keep system insets unchanged across the mode switch. Changing immersive
    // mode here relayouts both routes and can expose a blank platform frame.
  }

  Future<void> initSpeech() async {
    if (windows) await loadVoices();
    if (!mounted || exiting) return;
    await pollSession();
    if (!mounted || exiting) return;
    sessionPoll = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => pollSession(),
    );
    await callNative('brightness', brightness, true);
  }

  Future<dynamic> callNative(
    String method, [
    dynamic args,
    bool quiet = false,
  ]) async {
    try {
      final arguments = method == 'control'
          ? <String, dynamic>{
              ...?(args as Map<String, dynamic>?),
              'scope': widget.scope,
              'noteId': widget.noteId,
            }
          : args;
      return await (windows
              ? WindowsReaderSpeech.instance.invoke(
                  method,
                  arguments,
                  paragraphs: paragraphs,
                )
              : native.invokeMethod(method, arguments))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      if (!quiet && mounted) {
        setState(
          () => error = windows
              ? WindowsReaderSpeech.errorText(e)
              : e is PlatformException
              ? e.message
              : '此设备暂不能朗读，请检查系统离线语音设置。',
        );
      }
      return null;
    }
  }

  Future<void> loadVoices() async {
    final result = await callNative('voices');
    if (!mounted || result is! List) return;
    setState(() {
      voices = result.map((v) => Map<String, dynamic>.from(v as Map)).toList();
      if (!voices.any((v) => v['id'] == voice)) voice = '';
      if (!voices.any(
        (v) => (v['language'] as String? ?? '').startsWith('zh'),
      )) {
        error = '当前Windows系统未安装可用的中文语音。';
      } else {
        error = null;
      }
    });
  }

  Map<String, dynamic> anchor(int i) => {
    'index': i,
    'anchor': paragraphs[i].anchor,
  };
  Future<void> persist() {
    if (prefs == null || loading) return Future.value();
    final s = jsonEncode({
      'size': fontSize,
      'brightness': brightness,
      'line': lineHeight,
      'paragraph': paragraphSpacing,
      'spacing': spacing,
      'rate': rate,
      'repeat': repeat,
      'locked': locked,
      'theme': theme,
      'font': font,
      'language': language,
      'voice': voice,
    });
    final p = jsonEncode({
      'read': anchor(reading),
      'fraction': paragraphFraction,
      'speech': {...anchor(speaking), 'offset': speechOffset},
      'lastReadAt': DateTime.now().toUtc().toIso8601String(),
    });
    writes = writes
        .then((_) async {
          await prefs!.setString(settingsKey, s);
          await prefs!.setString(positionKey, p);
        })
        .catchError((_) {
          if (mounted) setState(() => error = '阅读设置保存失败，请检查本机存储空间。');
        });
    return writes;
  }

  void onScroll() {
    if (followScroll || seeking || playing) return;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () {
      capture();
      readingMoved = true;
      persist();
    });
  }

  void capture() {
    if (loading || seeking || followScroll || playing || !scroll.hasClients) {
      return;
    }
    for (final i in keys.keys.toList()..sort()) {
      final box = keys[i]?.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final y = box.localToGlobal(Offset.zero).dy;
        if (y + box.size.height > 30) {
          reading = i;
          paragraphFraction = ((30 - y) / box.size.height).clamp(0, .99);
          if (mounted) setState(() {});
          break;
        }
      }
    }
  }

  void restoreReading() {
    if (!mounted || !scroll.hasClients) return;
    if (playing) {
      if (!manualScroll) {
        followScroll = true;
        unawaited(
          alignSpeech(speaking, speechOffset, false, ++followGeneration),
        );
      }
      return;
    }
    final box = keys[reading]?.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final y = box.localToGlobal(Offset.zero).dy;
      scroll.jumpTo(
        (scroll.offset + y - 30 + paragraphFraction * box.size.height).clamp(
          scroll.position.minScrollExtent,
          scroll.position.maxScrollExtent,
        ),
      );
    }
  }

  double? initialPixels(double pixels) {
    final box = keys[reading]?.currentContext?.findRenderObject();
    if (box is! _ReaderParagraphBox || !box.hasSize) return null;
    var within = paragraphFraction * box.layoutHeight;
    final offset = initialParagraphOffset;
    if (offset != null) {
      RenderParagraph? text;
      void findText(RenderObject child) {
        if (child is RenderParagraph) {
          text ??= child;
        } else {
          child.visitChildren(findText);
        }
      }

      box.visitChildren(findText);
      if (text != null) {
        final caret = text!.getOffsetForCaret(
          TextPosition(offset: offset),
          Rect.zero,
        );
        within = paragraphSpacing / 2 + caret.dy;
        paragraphFraction = box.layoutHeight == 0
            ? 0
            : (within / box.layoutHeight).clamp(0, .99);
      }
    }
    final viewport = RenderAbstractViewport.of(box);
    return pixels +
        box.localToGlobal(Offset.zero, ancestor: viewport).dy +
        within;
  }

  void setting(VoidCallback action, {bool layout = false}) {
    if (layout) capture();
    setState(action);
    persist();
    if (layout) {
      WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
    }
  }

  /// An overlay must never reset a long note to its start. Capture the visible
  /// paragraph before the viewport changes and restore its anchor afterwards.
  void showReaderControls() {
    capture();
    setState(() => controls = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
  }

  void showReaderSettings() {
    capture();
    setState(() => settingsOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
  }

  void hideReaderSettings() {
    capture();
    setState(() {
      settingsOpen = false;
      controls = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
  }

  Future<void> pollSession() async {
    if (seeking || pollingSession) return;
    pollingSession = true;
    final requestSequence = sequence;
    try {
      final result = await callNative('snapshot', {
        'scope': widget.scope,
        'noteId': widget.noteId,
      }, true);
      if (!mounted ||
          requestSequence != sequence ||
          seeking ||
          result is! Map ||
          result.isEmpty ||
          paragraphs.isEmpty) {
        return;
      }
      if (result['active'] != true && restoredSession && !sessionActive) return;
      final restoring = !restoredSession;
      restoredSession = true;
      sessionActive = result['active'] == true;
      final wasPlaying = playing;
      setState(() {
        speaking = (result['index'] as num? ?? 0).toInt().clamp(
          0,
          paragraphs.length - 1,
        );
        speechOffset = (result['offset'] as num? ?? 0).toInt().clamp(
          0,
          paragraphs[speaking].text.length,
        );
        speechRangeEnd = (result['rangeEnd'] as num? ?? speechOffset + 1)
            .toInt()
            .clamp(speechOffset, paragraphs[speaking].text.length);
        playing = result['playing'] == true;
        speechOffset = readerTextBoundary(
          paragraphs[speaking].text,
          speechOffset,
        );
        speechRangeEnd = readerTextBoundary(
          paragraphs[speaking].text,
          speechRangeEnd,
          end: true,
        );
        if (sessionActive) {
          rate = normalizeReaderRate(
            (result['rate'] as num? ?? rate).toDouble(),
          );
        }
        if ((result['error'] as String? ?? '').isNotEmpty) {
          error = result['error'];
        }
      });
      if ((playing && speechRangeEnd > speechOffset) ||
          (!playing && wasPlaying) ||
          (restoring && sessionActive && widget.documentOffset == null)) {
        readingMoved = false;
        showPosition(speaking, speechOffset, smooth: playing);
      }
    } finally {
      pollingSession = false;
    }
  }

  bool onReaderScroll(ScrollNotification notification) {
    if (notification.depth != 0 || !playing) return false;
    final userStarted =
        notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
    if (userStarted) {
      manualScroll = true;
      followGeneration++;
      followScroll = false;
    }
    if (manualScroll) {
      resumeFollow?.cancel();
      resumeFollow = Timer(const Duration(seconds: 3), () {
        manualScroll = false;
        if (mounted && playing) {
          showPosition(speaking, speechOffset, smooth: true);
        }
      });
    }
    return false;
  }

  RenderParagraph? paragraphText(RenderObject root) {
    if (root is RenderParagraph) return root;
    RenderParagraph? found;
    root.visitChildren((child) {
      found ??= paragraphText(child);
    });
    return found;
  }

  Future<void> alignSpeech(
    int index,
    int offset,
    bool smooth,
    int generation,
  ) async {
    if (!mounted || generation != followGeneration || !scroll.hasClients) {
      return;
    }
    final box = keys[index]?.currentContext?.findRenderObject();
    final text = box == null ? null : paragraphText(box);
    if (text == null || !text.hasSize) {
      followScroll = false;
      return;
    }
    final viewport = RenderAbstractViewport.of(text) as RenderBox;
    final caret = text.getOffsetForCaret(
      TextPosition(offset: paragraphs[index].layoutOffset(offset)),
      Rect.zero,
    );
    final y = text.localToGlobal(caret, ancestor: viewport).dy;
    final target = (scroll.offset + y - viewport.size.height * .45).clamp(
      scroll.position.minScrollExtent,
      scroll.position.maxScrollExtent,
    );
    // A small dead band prevents word-by-word jitter on the same line.
    if ((target - scroll.offset).abs() < 8) {
      followScroll = false;
      return;
    }
    try {
      if (smooth) {
        await scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        scroll.jumpTo(target);
      }
    } finally {
      if (generation == followGeneration) followScroll = false;
    }
  }

  void showPosition(int index, int offset, {bool smooth = false}) {
    if (!mounted) return;
    if (smooth && manualScroll) return;
    debounce?.cancel();
    final changed = reading != index || speechOffset != offset;
    if (smooth && followScroll && !changed) return;
    followScroll = true;
    final generation = ++followGeneration;
    setState(() {
      reading = index;
      final length = paragraphs[index].text.length;
      paragraphFraction = length == 0 ? 0 : (offset / length).clamp(0, 1);
      if (keys[index]?.currentContext == null) {
        viewportAnchor = index;
        keys.clear();
        if (scroll.hasClients) scroll.jumpTo(0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != followGeneration) return;
      if (!smooth && !playing) {
        restoreReading();
        followScroll = false;
      } else {
        unawaited(alignSpeech(index, offset, smooth, generation));
      }
    });
  }

  void beginSeek(double value) {
    sequence++;
    resumeFollow?.cancel();
    manualScroll = false;
    resumeAfterSeek = playing;
    seeking = true;
    debounce?.cancel();
    setState(() => draggingProgress = value);
    seekPause = pauseSpeech();
  }

  Future<void> finishSeek(double value) async {
    await seekPause;
    await stop();
    if (!mounted) return;
    final position = progress.position(value);
    speaking = position.index;
    speechOffset = position.offset;
    readingMoved = true;
    showPosition(position.index, position.offset);
    setState(() {
      draggingProgress = null;
      seeking = false;
    });
    await persist();
    if (resumeAfterSeek) await play();
  }

  Future<void> play() async {
    if (starting) return;
    sequence++;
    setState(() {
      starting = true;
      error = null;
    });
    try {
      final session = await callNative('snapshot', {
        'scope': widget.scope,
        'noteId': widget.noteId,
      }, true);
      if (!readingMoved &&
          session is Map &&
          session['active'] == true &&
          session['index'] == speaking &&
          session['offset'] == speechOffset) {
        await callNative('control', {'action': 'resume'});
      } else {
        final position = progress.position(
          progress.fraction(reading, paragraphFraction),
        );
        speaking = position.index;
        speechOffset = position.offset;
        if (!windows && speechPath == null) {
          final root = await getApplicationSupportDirectory();
          final id = sha256.convert(
            utf8.encode(
              '${widget.scope}:${widget.noteId}:${widget.body.hashCode}',
            ),
          );
          speechPath = '${root.path}/reader_sessions/$id.jsonl';
          await compute(writeReaderSpeechFile, {
            'path': speechPath!,
            'body': widget.body,
          });
        }
        if (!mounted) return;
        await callNative('start', {
          'scope': widget.scope,
          'noteId': widget.noteId,
          'title': widget.title,
          'path': speechPath,
          'index': speaking,
          'offset': speechOffset,
          'rate': rate,
          'repeat': repeat,
          'language': language,
          'voice': voice,
        });
      }
      readingMoved = false;
      await pollSession();
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> pauseSpeech() async {
    await callNative('control', {'action': 'pause'});
    await pollSession();
    await persist();
  }

  Future<void> stop() async {
    sequence++;
    await callNative('control', {'action': 'stop'});
    if (mounted) {
      setState(() {
        playing = false;
        sessionActive = false;
      });
    }
    await persist();
  }

  Future<void> skip(int delta) async {
    sequence++;
    if (sessionActive) {
      await callNative('control', {'action': delta < 0 ? 'previous' : 'next'});
      await pollSession();
    } else {
      speaking = (speaking + delta).clamp(0, paragraphs.length - 1);
      speechOffset = 0;
      if (mounted) setState(() {});
    }
    showPosition(speaking, speechOffset);
    readingMoved = !sessionActive;
    await persist();
  }

  Future<void> configureSpeech() async {
    sequence++;
    await callNative('control', {
      'action': 'configure',
      'rate': rate,
      'repeat': repeat,
      'language': language,
      'voice': voice,
    });
  }

  Future<void> leave() async {
    if (exiting) return;
    exiting = true;
    sessionPoll?.cancel();
    capture();
    await persist();
    try {
      await NoteTypography.forScope(widget.scope).reload();
    } catch (e) {
      debugPrint('Reader typography refresh: $e');
    }
    await callNative('exit', null, true);
    nativeExited = true;
    if (mounted) {
      setState(() => leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      capture();
      unawaited(persist());
    }
  }

  @override
  void dispose() {
    resumeFollow?.cancel();
    followGeneration++;
    debounce?.cancel();
    unawaited(persist());
    activeId = null;
    sessionPoll?.cancel();
    if (!nativeExited) unawaited(callNative('exit', null, true));
    scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget paragraph(ReaderParagraph p, int index) {
    final base = TextStyle(
      color: foreground,
      fontSize: fontSize,
      height: NoteTypography.textHeight(fontSize, lineHeight),
      letterSpacing: spacing,
      fontFamily: font == 'source' ? 'SourceHanSans' : null,
    );
    return WindowsContentText(
      independentSize: true,
      child: _ReaderParagraphLayout(
        key: keys.putIfAbsent(index, () => GlobalKey()),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: paragraphSpacing / 2),
          child: Text.rich(
            TextSpan(children: speechSpans(p, index, base)),
            key: ValueKey('reader-paragraph-$index'),
            style: base,
          ),
        ),
      ),
    );
  }

  List<InlineSpan> speechSpans(ReaderParagraph p, int index, TextStyle base) {
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final run in p.runs) {
      final value = run['insert'];
      if (value is! String) {
        spans.add(WidgetSpan(child: image((value as Map)['image'])));
        continue;
      }
      final attributes = run['attributes'] as Map?;
      final style = base.copyWith(
        fontWeight: attributes?['bold'] == true ? FontWeight.bold : null,
        fontStyle: attributes?['italic'] == true ? FontStyle.italic : null,
        decoration: attributes?['underline'] == true
            ? TextDecoration.underline
            : null,
      );
      final start = (speechOffset - offset).clamp(0, value.length);
      final end = (speechRangeEnd - offset).clamp(0, value.length);
      if (playing && index == speaking && end > start) {
        if (start > 0) {
          spans.add(TextSpan(text: value.substring(0, start), style: style));
        }
        spans.add(
          TextSpan(
            text: value.substring(start, end),
            style: style.copyWith(
              backgroundColor: Colors.amber.withValues(alpha: .32),
            ),
          ),
        );
        if (end < value.length) {
          spans.add(TextSpan(text: value.substring(end), style: style));
        }
      } else {
        spans.add(TextSpan(text: value, style: style));
      }
      offset += value.length;
    }
    return spans;
  }

  Widget image(dynamic source) {
    try {
      if (source is String && source.startsWith('data:image/')) {
        return Image.memory(
          base64Decode(source.substring(source.indexOf(',') + 1)),
          errorBuilder: (_, _, _) => const Text('图片暂不可用'),
        );
      }
      if (source is String && Uri.tryParse(source)?.scheme == 'https') {
        return RoutedImage(
          source,
          errorBuilder: (_, _, _) => const Text('图片未缓存，联网后查看'),
        );
      }
    } catch (_) {}
    return const Text('附件');
  }

  Widget slider(
    String title,
    double value,
    double min,
    double max,
    int steps,
    void Function(double) change,
  ) => Row(
    children: [
      SizedBox(width: 75, child: Text(title)),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: steps,
          onChanged: change,
        ),
      ),
      Text(
        '${value.toStringAsFixed(title == '字号' ? 0 : 1)}${title == '语速' ? 'x' : ''}',
      ),
    ],
  );
  Widget panel() => Material(
    color: background,
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .48,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle(
            style: TextStyle(color: foreground, fontSize: 15),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '阅读进度：${(progress.fraction(reading, paragraphFraction) * 100).round()}% · 朗读 ${speaking + 1}/${paragraphs.length} 段',
                      ),
                    ),
                    IconButton(
                      tooltip: '隐藏控制栏',
                      onPressed: hideReaderSettings,
                      icon: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一段',
                      onPressed: starting ? null : () => skip(-1),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    TextButton(
                      onPressed: starting
                          ? null
                          : playing
                          ? pauseSpeech
                          : play,
                      child: Text(
                        starting
                            ? '准备语音…'
                            : playing
                            ? '暂停'
                            : '播放 / 继续',
                      ),
                    ),
                    IconButton(
                      tooltip: '下一段',
                      onPressed: starting ? null : () => skip(1),
                      icon: const Icon(Icons.skip_next),
                    ),
                    TextButton(onPressed: stop, child: const Text('停止')),
                    TextButton(
                      onPressed: () async {
                        await stop();
                        readingMoved = true;
                        speaking = reading;
                        speechOffset = 0;
                        await play();
                      },
                      child: const Text('从当前阅读处朗读'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('重复本文'),
                  subtitle: const Text('开启后，全文读完自动从头循环朗读'),
                  value: repeat,
                  onChanged: (v) {
                    setting(() => repeat = v);
                    configureSpeech();
                  },
                ),
                slider('语速', rate, .3, 3, 27, (v) {
                  setting(() => rate = normalizeReaderRate(v));
                  configureSpeech();
                }),
                slider(
                  '字号',
                  fontSize,
                  NoteTypography.minSize,
                  NoteTypography.maxSize,
                  NoteTypography.sizeDivisions,
                  (v) => setting(
                    () => fontSize = NoteTypography.normalizeSize(v),
                    layout: true,
                  ),
                ),
                slider('亮度', brightness, .05, 1, 19, (v) {
                  setting(() => brightness = v);
                  callNative('brightness', v, true);
                }),
                slider(
                  '行距',
                  lineHeight,
                  1.2,
                  2.6,
                  14,
                  (v) => setting(() => lineHeight = v, layout: true),
                ),
                slider(
                  '字距',
                  spacing,
                  -.5,
                  2,
                  10,
                  (v) => setting(() => spacing = v, layout: true),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in {
                      'dark': '夜间',
                      'paper': '纸张',
                      'light': '明亮',
                    }.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: theme == e.key,
                        onSelected: (_) => setting(() => theme = e.key),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in {
                      'system': '系统字体',
                      'source': '思源黑体',
                    }.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: font == e.key,
                        onSelected: (_) =>
                            setting(() => font = e.key, layout: true),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in {
                      'auto': '自动语言',
                      'zh': '中文',
                      'en': '英文',
                    }.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: language == e.key,
                        onSelected: (_) {
                          setting(() => language = e.key);
                          configureSpeech();
                        },
                      ),
                  ],
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () async {
                        await stop();
                        await callNative('settings');
                      },
                      child: Text(windows ? '打开Windows语音设置' : '系统语音设置'),
                    ),
                    if (!windows)
                      TextButton(
                        onPressed: () async {
                          await stop();
                          await callNative('install');
                        },
                        child: const Text('安装离线语音包'),
                      ),
                  ],
                ),
                if (windows)
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: voice,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('自动选择系统语音'),
                            ),
                            for (final v in voices)
                              DropdownMenuItem(
                                value: v['id'] as String,
                                child: Text(
                                  '${v['name']} (${v['language']})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setting(() => voice = value);
                            configureSpeech();
                          },
                        ),
                      ),
                      IconButton(
                        onPressed: loadVoices,
                        tooltip: '刷新系统语音',
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                if (!windows)
                  const Text('需要手机已安装对应语言的离线音色。部分引擎暂停后会从当前句或段开头继续。'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('防误编辑'),
                  subtitle: const Text('正文始终只读；开启时返回编辑需要再次确认'),
                  value: locked,
                  onChanged: (v) => setting(() => locked = v),
                ),
                TextButton(
                  onPressed: () async {
                    final yes =
                        !locked ||
                        await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('退出阅读，返回编辑？'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('继续阅读'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('返回编辑'),
                                  ),
                                ],
                              ),
                            ) ==
                            true;
                    if (yes) {
                      await stop();
                      await leave();
                    }
                  },
                  child: const Text('完全退出阅读 / 停止朗读'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> searchReader() async {
    final input = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('在此笔记中搜索'),
        content: TextField(
          controller: input,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, input.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (!mounted || query == null || query.trim().isEmpty) return;
    final hits = <int>[];
    for (var i = 0; i < paragraphs.length && hits.length < 200; i++) {
      if (paragraphs[i].text.toLowerCase().contains(query.toLowerCase())) {
        hits.add(i);
      }
    }
    final hit = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: hits.isEmpty
            ? const Padding(padding: EdgeInsets.all(20), child: Text('未找到匹配内容'))
            : ListView(
                children: [
                  for (final i in hits)
                    ListTile(
                      title: Text(
                        paragraphs[i].text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('第 ${i + 1} 段'),
                      onTap: () => Navigator.pop(c, i),
                    ),
                ],
              ),
      ),
    );
    if (!mounted || hit == null) return;
    readingMoved = true;
    setState(() {
      reading = hit;
      viewportAnchor = hit;
      paragraphFraction = 0;
      keys.clear();
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
  }

  Future<void> exportReader() async {
    try {
      await FilePicker.platform.saveFile(
        dialogTitle: '导出 TXT',
        fileName: '笔记_${DateTime.now().millisecondsSinceEpoch}.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: Uint8List.fromList(
          utf8.encode(NoteRichContent.plainText(widget.body)),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '导出未完成，原笔记保留。');
    }
  }

  void shareFromBar(String action) {
    if (widget.app == null) return;
    shareReadingNote(
      context,
      widget.app!,
      action,
      id: widget.noteId,
      storedNote: widget.storedNote,
      title: widget.title,
      body: widget.body,
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving,
    onPopInvokedWithResult: (didPop, _) async {
      if (!didPop) {
        if (settingsOpen) {
          hideReaderSettings();
        } else if (controls) {
          setState(() => controls = false);
        } else {
          await leave();
        }
      }
    },
    child: Theme(
      data: ThemeData(
        brightness: theme == 'dark' ? Brightness.dark : Brightness.light,
        colorSchemeSeed: Colors.amber,
        scaffoldBackgroundColor: background,
      ),
      child: Scaffold(
        backgroundColor: background,
        body: SafeArea(
          child: Column(
            children: [
              if (controls)
                AdaptiveActionBar(
                  menuIndex: 1,
                  actions: [
                    BarAction(
                      '阅读设置',
                      showReaderSettings,
                      icon: Icons.chrome_reader_mode_outlined,
                      visualScale: .85,
                    ),
                    BarAction('返回', leave, visualScale: .85),
                  ],
                  menu: PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_horiz,
                      color: foreground,
                      size: 24 * 1.12,
                    ),
                    onSelected: (action) async {
                      if (action == 'search') {
                        await searchReader();
                      } else if (action == 'redbook' || action == 'chat') {
                        shareFromBar(action);
                      } else if (action == 'export') {
                        await exportReader();
                      } else if ([
                            'pin',
                            'quick',
                            'history',
                            'duplicate',
                            'trash',
                            'move_space',
                            'copy_space',
                          ].contains(action) &&
                          widget.app != null &&
                          widget.storedNote) {
                        final exit = await runNoteTool(
                          context,
                          widget.app!,
                          widget.noteId,
                          action,
                        );
                        if (exit) await leave();
                      } else if (action == 'internal') {
                        await Clipboard.setData(
                          ClipboardData(
                            text: 'huideng://note/${widget.noteId}',
                          ),
                        );
                      } else if (action == 'typography') {
                        await persist();
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                NoteTypographyPage(scope: widget.scope),
                          ),
                        );
                        final t = NoteTypography.forScope(widget.scope);
                        await t.reload();
                        if (mounted) {
                          setting(() {
                            fontSize = t.size;
                            lineHeight = t.line;
                            paragraphSpacing = t.paragraph;
                            font = t.font;
                          }, layout: true);
                        }
                      } else if (widget.app != null && widget.storedNote) {
                        await shareReadingNote(
                          context,
                          widget.app!,
                          action,
                          id: widget.noteId,
                          storedNote: widget.storedNote,
                          title: widget.title,
                          body: widget.body,
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      if (widget.app != null)
                        const PopupMenuItem(
                          value: 'redbook',
                          child: Text('发布红书'),
                        ),
                      if (widget.app != null)
                        const PopupMenuItem(value: 'chat', child: Text('分享聊天')),
                      const PopupMenuItem(
                        value: 'search',
                        child: Text('在此笔记中搜索'),
                      ),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出 TXT'),
                      ),
                      const PopupMenuItem(
                        value: 'typography',
                        child: Text('排版'),
                      ),
                      if (widget.storedNote)
                        const PopupMenuItem(
                          value: 'internal',
                          child: Text('复制 APP 内部笔记链接'),
                        ),
                      if (widget.app != null && widget.storedNote) ...[
                        const PopupMenuItem(
                          value: 'pin',
                          child: Text('置顶 / 取消置顶'),
                        ),
                        const PopupMenuItem(
                          value: 'quick',
                          child: Text('收藏 / 取消收藏'),
                        ),
                        const PopupMenuItem(
                          value: 'history',
                          child: Text('版本历史'),
                        ),
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: Text('创建副本'),
                        ),
                        const PopupMenuItem(
                          value: 'move_space',
                          child: Text('加入 / 移动到分类'),
                        ),
                        const PopupMenuItem(
                          value: 'copy_space',
                          child: Text('复制到分类'),
                        ),
                        const PopupMenuItem(
                          value: 'trash',
                          child: Text('移至回收站'),
                        ),

                        const PopupMenuItem(
                          value: 'publish',
                          child: Text('生成 / 更新网页链接'),
                        ),
                        const PopupMenuItem(
                          value: 'get',
                          child: Text('复制网页链接'),
                        ),
                        const PopupMenuItem(
                          value: 'revoke',
                          child: Text('取消公开链接'),
                        ),
                      ],
                    ],
                  ),
                ),
              if (error != null && (controls || settingsOpen))
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.orange),
                  ),
                ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: showReaderControls,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: onReaderScroll,
                          child: CustomScrollView(
                            controller: scroll,
                            center: centerKey,
                            slivers: [
                              SliverList.builder(
                                itemCount: viewportAnchor,
                                itemBuilder: (_, i) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: paragraph(
                                    paragraphs[viewportAnchor - i - 1],
                                    viewportAnchor - i - 1,
                                  ),
                                ),
                              ),
                              SliverList(
                                key: centerKey,
                                delegate: SliverChildBuilderDelegate(
                                  (_, i) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: paragraph(
                                      paragraphs[viewportAnchor + i],
                                      viewportAnchor + i,
                                    ),
                                  ),
                                  childCount:
                                      paragraphs.length - viewportAnchor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              if (!loading)
                Row(
                  children: [
                    IconButton(
                      tooltip: '阅读设置',
                      onPressed: showReaderSettings,
                      icon: Icon(Icons.tune, color: foreground),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('reader-progress'),
                        value:
                            draggingProgress ??
                            progress.fraction(reading, paragraphFraction),
                        onChangeStart: starting ? null : beginSeek,
                        onChanged: starting
                            ? null
                            : (v) => setState(() => draggingProgress = v),
                        onChangeEnd: starting ? null : finishSeek,
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${((draggingProgress ?? progress.fraction(reading, paragraphFraction)) * 100).round()}%',
                        style: TextStyle(color: foreground),
                      ),
                    ),
                  ],
                ),
              if (settingsOpen && !loading) panel(),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Restore after paragraph layout but before paint, avoiding a visible jump on
/// the next frame. Returning false asks the viewport to relayout immediately.
class _ReaderParagraphLayout extends SingleChildRenderObjectWidget {
  const _ReaderParagraphLayout({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReaderParagraphBox();
}

class _ReaderParagraphBox extends RenderProxyBox {
  double layoutHeight = 0;
  @override
  void performLayout() {
    super.performLayout();
    layoutHeight = size.height;
  }
}

class _ReaderScrollController extends ScrollController {
  _ReaderScrollController(this.initialPixels);
  final double? Function(double) initialPixels;
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ReaderScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialPixels,
  );
}

class _ReaderScrollPosition extends ScrollPositionWithSingleContext {
  _ReaderScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.initialPixels,
  });
  final double? Function(double) initialPixels;
  bool restored = false;
  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (!restored) {
      final target = initialPixels(pixels);
      if (target != null) {
        restored = true;
        final bounded = target.clamp(minScrollExtent, maxScrollExtent);
        if ((bounded - pixels).abs() > .5) {
          correctPixels(bounded);
          return false;
        }
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

Future<void> writeReaderSpeechFile(Map<String, String> input) async {
  final file = File(input['path']!);
  await file.parent.create(recursive: true);
  final sink = File('${file.path}.part').openWrite();
  try {
    var count = 0;
    for (final p in readerParagraphs(input['body']!)) {
      sink.writeln(jsonEncode({'text': p.text}));
      if (++count % 128 == 0) await sink.flush();
    }
  } finally {
    await sink.close();
  }
  await File('${file.path}.part').rename(file.path);
}
