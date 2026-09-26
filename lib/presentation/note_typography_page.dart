import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NoteTypography extends ChangeNotifier {
  static final _scopes = <String, NoteTypography>{};
  static NoteTypography forScope(String scope) =>
      _scopes.putIfAbsent(scope, () => NoteTypography._(scope));
  NoteTypography._(this.scope) {
    ready = reload();
  }
  final String scope;
  late Future<void> ready;
  double size = 22, line = 2.05, paragraph = 10;
  String font = 'system';
  String get key => 'reader.preferences.v1.$scope';
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
    double value(String key, double fallback, double min, double max) =>
        data[key] is num
        ? (data[key] as num).toDouble().clamp(min, max)
        : fallback;
    size = value('size', 22, 12, 40);
    line = value('line', 2.05, 1.2, 2.6);
    paragraph = value('paragraph', 10, 0, 32);
    font = data['font'] == 'source' ? 'source' : 'system';
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = Map<String, dynamic>.from(
      jsonDecode(prefs.getString(key) ?? '{}') as Map,
    );
    data.addAll({
      'size': size,
      'line': line,
      'paragraph': paragraph,
      'font': font,
    });
    if (!await prefs.setString(key, jsonEncode(data))) {
      throw StateError('无法保存排版');
    }
    notifyListeners();
  }
}

class NoteTypographyPage extends StatefulWidget {
  const NoteTypographyPage({super.key, required this.scope});
  final String scope;
  @override
  State<NoteTypographyPage> createState() => _TypographyState();
}

class _TypographyState extends State<NoteTypographyPage> {
  late final settings = NoteTypography.forScope(widget.scope);
  Future<void> writes = Future.value();
  String? error;
  void change(VoidCallback update) {
    setState(update);
    writes = writes.then((_) => settings.save()).catchError((Object e) {
      if (mounted) setState(() => error = '排版未能保存，请检查本机存储空间。');
    });
  }

  Widget slider(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$title：${value.toStringAsFixed(1)}'),
      Slider(
        value: value,
        min: min,
        max: max,
        onChanged: (v) => change(() => update(v)),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('笔记排版'),
      actions: [
        TextButton(
          onPressed: () => change(() {
            settings.size = 22;
            settings.line = 2.05;
            settings.paragraph = 10;
            settings.font = 'system';
          }),
          child: const Text('重置'),
        ),
      ],
    ),
    body: FutureBuilder(
      future: settings.ready,
      builder: (context, snapshot) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('所有笔记共用；不会改变正文内容或局部加粗等格式。'),
          DropdownButton<String>(
            value: settings.font,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'system', child: Text('系统字体')),
              DropdownMenuItem(value: 'source', child: Text('思源黑体')),
            ],
            onChanged: (v) => change(() => settings.font = v!),
          ),
          slider('字体大小', settings.size, 12, 40, (v) => settings.size = v),
          slider('行距', settings.line, 1.2, 2.6, (v) => settings.line = v),
          slider(
            '段落间距',
            settings.paragraph,
            0,
            32,
            (v) => settings.paragraph = v,
          ),
          if (error != null) Text(error!),
          Text(
            '愿以清净心，安住当下。\nRead slowly and clearly.',
            style: TextStyle(
              fontSize: settings.size,
              height: settings.line,
              fontFamily: settings.font == 'source' ? 'SourceHanSans' : null,
            ),
          ),
          SizedBox(height: settings.paragraph),
          Text(
            '在阅读中沉淀，在实践中成长。',
            style: TextStyle(
              fontSize: settings.size,
              height: settings.line,
              fontFamily: settings.font == 'source' ? 'SourceHanSans' : null,
            ),
          ),
        ],
      ),
    ),
  );
}
