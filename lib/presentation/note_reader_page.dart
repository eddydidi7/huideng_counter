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
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/note_reader.dart';
import 'routed_image.dart';

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
  });
  final String body, noteId, scope, title;
  final AppController? app;
  final bool storedNote;
  @override
  State<NoteReaderPage> createState() => _NoteReaderPageState();
}

class _NoteReaderPageState extends State<NoteReaderPage>
    with WidgetsBindingObserver {
  static const native = MethodChannel('org.huideng.counter/reader');
  List<ReaderParagraph> paragraphs = [];
  final keys = <int, GlobalKey>{};
  final centerKey = GlobalKey();
  int viewportAnchor = 0;
  Timer? sessionPoll;
  String? speechPath;
  bool sessionActive = false, restoredSession = false;
  final scroll = ScrollController();
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
  double fontSize = 22,
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
      paragraphs = widget.body.length < 100000
          ? readerParagraphs(widget.body)
          : await compute(readerParagraphs, widget.body);
      prefs = await SharedPreferences.getInstance();
      final s = jsonDecode(prefs!.getString(settingsKey) ?? '{}') as Map;
      fontSize = bounded(s['size'], 22, 12, 40);
      brightness = bounded(s['brightness'], .65, .05, 1);
      lineHeight = bounded(s['line'], 2.05, 1.2, 2.6);
      paragraphSpacing = bounded(s['paragraph'], 10, 0, 32);
      spacing = bounded(s['spacing'], 0, -.5, 2);
      rate = normalizeReaderRate(bounded(s['rate'], 1, .3, 3));
      repeat = s['repeat'] == true;
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
    viewportAnchor = reading;
    await pollSession();
    if (!mounted) return;
    sessionPoll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => pollSession(),
    );
    setState(() => loading = false);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await callNative('brightness', brightness, true);
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreReading());
  }

  Future<dynamic> callNative(
    String method, [
    dynamic args,
    bool quiet = false,
  ]) async {
    try {
      return await native
          .invokeMethod(
            method,
            method == 'control'
                ? <String, dynamic>{
                    ...?(args as Map<String, dynamic>?),
                    'scope': widget.scope,
                    'noteId': widget.noteId,
                  }
                : args,
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      if (!quiet && mounted) {
        setState(
          () => error = e is PlatformException
              ? e.message
              : '此设备暂不能朗读，请检查系统离线语音设置。',
        );
      }
      return null;
    }
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
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () {
      capture();
      persist();
    });
  }

  void capture() {
    if (loading || !scroll.hasClients) return;
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
    final result = await callNative('snapshot', {
      'scope': widget.scope,
      'noteId': widget.noteId,
    }, true);
    if (!mounted || result is! Map || result.isEmpty || paragraphs.isEmpty) {
      return;
    }
    if (result['active'] != true && restoredSession && !sessionActive) return;
    restoredSession = true;
    sessionActive = result['active'] == true;
    setState(() {
      speaking = (result['index'] as num? ?? 0).toInt().clamp(
        0,
        paragraphs.length - 1,
      );
      speechOffset = (result['offset'] as num? ?? 0).toInt();
      playing = result['playing'] == true;
      if (sessionActive) {
        rate = normalizeReaderRate((result['rate'] as num? ?? rate).toDouble());
      }
      if ((result['error'] as String? ?? '').isNotEmpty) {
        error = result['error'];
      }
    });
  }

  Future<void> play() async {
    if (starting) return;
    setState(() {
      starting = true;
      error = null;
    });
    try {
      final session = await callNative('snapshot', {
        'scope': widget.scope,
        'noteId': widget.noteId,
      }, true);
      if (session is Map &&
          session['active'] == true &&
          session['index'] == speaking &&
          session['offset'] == speechOffset) {
        await callNative('control', {'action': 'resume'});
      } else {
        if (speechPath == null) {
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
        });
      }
      await pollSession();
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> pauseSpeech() async {
    await callNative('control', {'action': 'pause'}, true);
    await pollSession();
    await persist();
  }

  Future<void> stop() async {
    await callNative('control', {'action': 'stop'}, true);
    if (mounted) setState(() => playing = false);
    await persist();
  }

  Future<void> skip(int delta) async {
    if (sessionActive) {
      await callNative('control', {'action': delta < 0 ? 'previous' : 'next'});
      await pollSession();
    } else {
      speaking = (speaking + delta).clamp(0, paragraphs.length - 1);
      speechOffset = 0;
      if (mounted) setState(() {});
    }
    await persist();
  }

  Future<void> configureSpeech() async {
    await callNative('control', {
      'action': 'configure',
      'rate': rate,
      'repeat': repeat,
      'language': language,
    }, true);
  }

  Future<void> leave() async {
    capture();
    await persist();
    try {
      await NoteTypography.forScope(widget.scope).reload();
    } catch (e) {
      debugPrint('Reader typography refresh: $e');
    }
    await callNative('exit', null, true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    debounce?.cancel();
    unawaited(persist());
    activeId = null;
    sessionPoll?.cancel();
    unawaited(callNative('exit', null, true));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget paragraph(ReaderParagraph p, int index) {
    final base = TextStyle(
      color: foreground,
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: spacing,
      fontFamily: font == 'source' ? 'SourceHanSans' : null,
    );
    return Container(
      key: keys.putIfAbsent(index, () => GlobalKey()),
      padding: EdgeInsets.symmetric(vertical: paragraphSpacing / 2),
      color: playing && index == speaking
          ? Colors.amber.withValues(alpha: .18)
          : null,
      child: Text.rich(
        TextSpan(
          children: [
            for (final r in p.runs)
              if (r['insert'] is String)
                TextSpan(
                  text: r['insert'],
                  style: base.copyWith(
                    fontWeight: (r['attributes'] as Map?)?['bold'] == true
                        ? FontWeight.bold
                        : null,
                    fontStyle: (r['attributes'] as Map?)?['italic'] == true
                        ? FontStyle.italic
                        : null,
                    decoration: (r['attributes'] as Map?)?['underline'] == true
                        ? TextDecoration.underline
                        : null,
                  ),
                )
              else
                WidgetSpan(child: image((r['insert'] as Map)['image'])),
          ],
        ),
        style: base,
      ),
    );
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
                        '阅读进度：${((reading + paragraphFraction) / paragraphs.length * 100).round()}% · 朗读 ${speaking + 1}/${paragraphs.length} 段',
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
                  12,
                  40,
                  28,
                  (v) => setting(() => fontSize = v, layout: true),
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
                      child: const Text('系统语音设置'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await stop();
                        await callNative('install');
                      },
                      child: const Text('安装离线语音包'),
                    ),
                  ],
                ),
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
                      color: const Color(0xff90caf9),
                    ),
                    BarAction('返回', leave),
                  ],
                  menu: PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: foreground),
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
                                childCount: paragraphs.length - viewportAnchor,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              if (settingsOpen && !loading) panel(),
            ],
          ),
        ),
      ),
    ),
  );
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
