import 'dart:async';
import 'package:flutter/material.dart';
import '../services/forum_card_layout.dart';

class ForumCardEditor extends StatefulWidget {
  const ForumCardEditor({
    super.key,
    required this.initial,
    required this.onDraft,
  });
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic>) onDraft;
  @override
  State<ForumCardEditor> createState() => _ForumCardEditorState();
}

class _ForumCardEditorState extends State<ForumCardEditor> {
  late final text = TextEditingController(
    text: widget.initial['text'] as String? ?? '',
  );
  late ForumCardStyle style = ForumCardStyle.fromJson(
    Map<String, dynamic>.from(widget.initial['style'] as Map? ?? {}),
  );
  final pager = PageController();
  List<String> pages = [''];
  int selected = 0;
  String? error;
  Timer? timer;
  bool saving = false, leaving = false;
  Map<String, dynamic> get draft => {
    'text': text.text,
    'style': style.toJson(),
  };
  @override
  void initState() {
    super.initState();
    reflow();
    text.addListener(changed);
  }

  void reflow() {
    try {
      pages = paginateForumCard(text.text, style);
      selected = selected.clamp(0, pages.length - 1);
      error = null;
    } catch (e) {
      error = e.toString();
    }
  }

  void changed() {
    timer?.cancel();
    setState(reflow);
    if (pager.hasClients && pager.page?.round() != selected) {
      pager.jumpToPage(selected);
    }
    timer = Timer(const Duration(milliseconds: 250), () => persist());
  }

  void show(int page) {
    setState(() => selected = page);
    if (pager.hasClients) {
      pager.animateToPage(
        page,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<bool> persist() async {
    try {
      await widget.onDraft(draft);
      return true;
    } catch (_) {
      if (mounted) setState(() => error = '草稿保存失败，请不要退出，稍后重试。');
      return false;
    }
  }

  Future<void> finish(bool use) async {
    if (saving || (use && (error != null || text.text.trim().isEmpty))) return;
    setState(() => saving = true);
    timer?.cancel();
    if (await persist()) {
      if (!mounted) return;
      setState(() => leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context, use ? draft : null);
    }
    if (mounted) setState(() => saving = false);
  }

  @override
  void dispose() {
    timer?.cancel();
    text.dispose();
    pager.dispose();
    super.dispose();
  }

  Future<void> color(bool background) async {
    var hsv = HSVColor.fromColor(
      background ? style.background : style.textColor,
    );
    final hex = TextEditingController(
      text: hsv.toColor().toARGB32().toRadixString(16).substring(2),
    );
    final route = DialogRoute<Color>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(background ? '自定义背景主色' : '自定义文字颜色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: 48, color: hsv.toColor()),
                for (final field in ['色相', '饱和度', '明度'])
                  Row(
                    children: [
                      Text(field),
                      Expanded(
                        child: Slider(
                          value: field == '色相'
                              ? hsv.hue / 360
                              : field == '饱和度'
                              ? hsv.saturation
                              : hsv.value,
                          onChanged: (v) => update(() {
                            hsv = field == '色相'
                                ? hsv.withHue(v * 360)
                                : field == '饱和度'
                                ? hsv.withSaturation(v)
                                : hsv.withValue(v);
                            hex.text = hsv
                                .toColor()
                                .toARGB32()
                                .toRadixString(16)
                                .substring(2);
                          }),
                        ),
                      ),
                    ],
                  ),
                TextField(
                  controller: hex,
                  decoration: const InputDecoration(labelText: 'HEX，例如 E3F1DF'),
                  onChanged: (v) {
                    final n = int.tryParse(v.replaceAll('#', ''), radix: 16);
                    if (n != null && v.replaceAll('#', '').length == 6) {
                      update(
                        () => hsv = HSVColor.fromColor(Color(0xff000000 | n)),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, hsv.toColor()),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    hex.dispose();
    if (!mounted) return;
    if (result != null) {
      if (background) {
        style.background = result;
      } else {
        style.requestedText = result;
      }
      changed();
    }
  }

  Widget label(String value) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text(value, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) set, {
    int? divisions,
  }) => Row(
    children: [
      SizedBox(width: 48, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) {
            set(v);
            changed();
          },
        ),
      ),
      SizedBox(
        width: 36,
        child: Text(value.toStringAsFixed(divisions != null ? 0 : 1)),
      ),
    ],
  );

  /// Mini cards: every template shown in the currently chosen colour.
  Widget templatePicker() => SizedBox(
    height: 112,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: forumCardTemplates.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (_, i) {
        final template = forumCardTemplates[i];
        final sample = ForumCardStyle.fromJson({
          ...style.toJson(),
          'template': template.id,
          'size': 30,
          'text': null,
        });
        final active = style.template == template.id;
        return GestureDetector(
          key: ValueKey('card-template-${template.id}'),
          onTap: () {
            style.template = template.id;
            changed();
          },
          child: Column(
            children: [
              Container(
                width: 63,
                height: 84,
                decoration: BoxDecoration(
                  border: Border.all(
                    width: active ? 2 : 1,
                    color: active
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).dividerColor,
                  ),
                ),
                child: ForumCardPreview(
                  text: '闻思修',
                  style: sample,
                  page: 0,
                  total: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                template.name,
                style: TextStyle(
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget colorPicker() => Wrap(
    spacing: 10,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final e in forumCardColors.entries)
        Tooltip(
          message: e.key,
          child: InkWell(
            key: ValueKey('card-color-${e.key}'),
            customBorder: const CircleBorder(),
            onTap: () {
              style.background = e.value;
              changed();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: e.value,
                    shape: BoxShape.circle,
                    border: Border.all(
                      width: style.background == e.value ? 3 : 1,
                      color: style.background == e.value
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: ForumCardPalette.from(e.value).accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Text(e.key, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      TextButton(
        onPressed: () => color(true),
        child: const Text('自定义颜色'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving,
    onPopInvokedWithResult: (did, _) {
      if (!did) finish(false);
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('文字生成图片'),
        actions: [
          TextButton(
            onPressed: saving ? null : () => finish(true),
            child: const Text('使用全部页面'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: PageView.builder(
                  key: const ValueKey('card-preview-pages'),
                  controller: pager,
                  itemCount: pages.length,
                  onPageChanged: (i) => setState(() => selected = i),
                  itemBuilder: (_, i) => ForumCardPreview(
                    text: pages[i],
                    style: style,
                    page: i,
                    total: pages.length,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Text(
              '${selected + 1} / ${pages.length}',
              key: const ValueKey('card-page-indicator'),
            ),
          ),
          if (pages.length > 1)
            Center(
              child: Text(
                '左右滑动查看全部 ${pages.length} 页',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (pages.length > 1)
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: pages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) => GestureDetector(
                  onTap: () => show(i),
                  child: Container(
                    width: 65,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selected == i
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: AspectRatio(
                            aspectRatio: 3 / 4,
                            child: ForumCardPreview(
                              text: pages[i],
                              style: style,
                              page: i,
                              total: pages.length,
                            ),
                          ),
                        ),
                        Text('${i + 1}'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          label('模板'),
          templatePicker(),
          label('配色'),
          colorPicker(),
          TextField(
            controller: text,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '文字内容',
              helperText: '分页符处会强制换页；文字过长会自动分页',
            ),
          ),
          TextButton.icon(
            onPressed: () {
              final p = text.selection.isValid
                  ? text.selection.start
                  : text.text.length;
              text.value = TextEditingValue(
                text: text.text.replaceRange(p, p, '\f'),
                selection: TextSelection.collapsed(offset: p + 1),
              );
            },
            icon: const Icon(Icons.insert_page_break_outlined),
            label: const Text('从这里分页 / 下一页'),
          ),
          label('文字'),
          slider(
            '字号',
            style.size,
            16,
            60,
            (v) => style.size = v,
            divisions: 44,
          ),
          slider('行距', style.line, 1.1, 2.2, (v) => style.line = v),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final w in forumCardWeights.keys)
                ChoiceChip(
                  label: Text(w),
                  selected: style.weight == w,
                  onSelected: (_) {
                    style.weight = w;
                    changed();
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final a in {
                TextAlign.left: '左对齐',
                TextAlign.center: '居中',
                TextAlign.right: '右对齐',
                TextAlign.justify: '两端对齐',
              }.entries)
                ChoiceChip(
                  label: Text(a.value),
                  selected: style.align == a.key,
                  onSelected: (_) {
                    style.align = a.key;
                    changed();
                  },
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => color(false),
                child: const Text('文字颜色'),
              ),
              TextButton(
                onPressed: () {
                  style.requestedText = null;
                  changed();
                },
                child: const Text('自动文字颜色'),
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('更多设置'),
            children: [
              slider('字距', style.spacing, 0, 4, (v) => style.spacing = v),
              slider('边距', style.margin, 16, 40, (v) => style.margin = v),
              DropdownButtonFormField<String>(
                initialValue: style.font,
                decoration: const InputDecoration(labelText: '字体'),
                items: const [
                  DropdownMenuItem(value: 'system', child: Text('系统默认')),
                  DropdownMenuItem(value: 'source', child: Text('思源黑体')),
                ],
                onChanged: (v) {
                  style.font = v!;
                  changed();
                },
              ),
            ],
          ),
          const Text('同一模板可换任意配色；文字颜色对比不足时会自动改用清晰的颜色。'),
        ],
      ),
    ),
  );
}

class ForumCardPreview extends StatelessWidget {
  const ForumCardPreview({
    super.key,
    required this.text,
    required this.style,
    required this.page,
    required this.total,
  });
  final String text;
  final ForumCardStyle style;
  final int page, total;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _CardPainter(text, style, page, total));
}

class _CardPainter extends CustomPainter {
  _CardPainter(this.text, this.style, this.page, this.total);
  final String text;
  final ForumCardStyle style;
  final int page, total;
  @override
  void paint(Canvas c, Size s) =>
      paintForumCard(c, s, text, style, page, total);
  @override
  bool shouldRepaint(covariant _CardPainter old) => true;
}
