import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Logical page size; export scales the same layout 3x (1080 x 1440).
const forumCardWidth = 360.0, forumCardHeight = 480.0;
const _footerHeight = 20.0;

/// Quick base colors. Each one is only a base: every template derives its
/// own background, text, decoration and accent colors from it.
const forumCardColors = <String, Color>{
  '淡蓝': Color(0xffe0edf7),
  '淡紫': Color(0xffebe3f5),
  '淡黄': Color(0xfffff3cb),
  '淡绿': Color(0xffe3f1df),
  '白色': Color(0xffffffff),
  '黑色': Color(0xff121212),
  '红色': Color(0xffb23a3a),
  '米色': Color(0xfff5ecdc),
  '淡粉': Color(0xfff8e3eb),
  '浅灰': Color(0xffeeeeee),
  '深灰': Color(0xff36383d),
};

double forumCardContrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

/// Colour roles generated from one base colour. Templates paint only with
/// these roles, so a new template automatically supports every colour.
class ForumCardPalette {
  const ForumCardPalette({
    required this.background,
    required this.panel,
    required this.text,
    required this.muted,
    required this.accent,
    required this.decoration,
    required this.dark,
  });
  final Color background, panel, text, muted, accent, decoration;
  final bool dark;

  factory ForumCardPalette.from(Color base) {
    const ink = Color(0xff161616), paper = Color(0xfffafafa);
    final color = base.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(color);
    final dark =
        forumCardContrast(paper, color) > forumCardContrast(ink, color);
    // Neutral bases (white, grey, black) get a calm warm accent hue.
    final neutral = hsl.saturation < .08;
    final hue = neutral ? 35.0 : hsl.hue;
    final saturation = neutral ? .45 : hsl.saturation;

    final panel = dark
        ? hsl.withLightness((hsl.lightness + .07).clamp(0, 1)).toColor()
        : hsl.lightness > .95
        ? hsl.withLightness(hsl.lightness - .035).toColor()
        : Color.lerp(color, Colors.white, .55)!;

    Color readable(Color preferred) {
      double worst(Color c) => math.min(
        forumCardContrast(c, color),
        forumCardContrast(c, panel),
      );
      if (worst(preferred) >= 7) return preferred;
      // Pure black/white give the most headroom on mid-tone bases.
      return worst(Colors.black) >= worst(Colors.white)
          ? Colors.black
          : Colors.white;
    }

    final text = readable(
      dark
          ? HSLColor.fromAHSL(1, hue, math.min(saturation, .25), .93).toColor()
          : HSLColor.fromAHSL(1, hue, math.min(saturation, .45), .16).toColor(),
    );
    var accent = HSLColor.fromAHSL(
      1,
      hue,
      math.max(saturation, .5).clamp(0, .85),
      dark ? .7 : .42,
    ).toColor();
    if (forumCardContrast(accent, color) < 3) accent = text;
    var muted = Color.lerp(text, color, .35)!;
    if (forumCardContrast(muted, color) < 4.5) muted = text;
    return ForumCardPalette(
      background: color,
      panel: panel,
      text: text,
      muted: muted,
      accent: accent,
      decoration: accent.withValues(alpha: dark ? .35 : .28),
      dark: dark,
    );
  }
}

typedef ForumCardPainter =
    void Function(Canvas canvas, ForumCardPalette palette, Rect textArea);

/// A layout/decoration design. It never fixes colours; add a new template by
/// appending to [forumCardTemplates] and it works with every palette.
class ForumCardTemplate {
  const ForumCardTemplate({
    required this.id,
    this.inset = EdgeInsets.zero,
    this.onPanel = false,
    this.behind,
    this.front,
  });
  final String id;

  /// Space reserved inside the page margin for decoration.
  final EdgeInsets inset;

  /// Text sits on palette.panel instead of palette.background.
  final bool onPanel;

  /// Painted before the text (may cover the page); keep it faint.
  final ForumCardPainter? behind;

  /// Painted after the text; must stay outside the text area.
  final ForumCardPainter? front;
  String get name => id;
}

const _page = Rect.fromLTWH(0, 0, forumCardWidth, forumCardHeight);

final forumCardTemplates = <ForumCardTemplate>[
  ForumCardTemplate(
    id: '基础',
    inset: const EdgeInsets.only(top: 10),
    front: (c, p, t) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(t.left, t.top - 14, 30, 4),
          const Radius.circular(2),
        ),
        Paint()..color = p.accent,
      );
      c.drawCircle(Offset(t.left + 38, t.top - 12), 2, Paint()..color = p.accent);
    },
  ),
  ForumCardTemplate(
    id: '札记',
    inset: const EdgeInsets.only(top: 16, left: 8),
    behind: (c, p, t) {
      final line = Paint()
        ..color = p.text.withValues(alpha: .08)
        ..strokeWidth = 1;
      for (var y = t.top + 30.0; y < t.bottom; y += 30) {
        c.drawLine(Offset(0, y), Offset(forumCardWidth, y), line);
      }
      c.drawLine(
        Offset(t.left - 10, 0),
        Offset(t.left - 10, forumCardHeight),
        Paint()
          ..color = p.decoration
          ..strokeWidth = 1.5,
      );
    },
    front: (c, p, t) {
      final ring = Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      for (var x = 40.0; x < forumCardWidth - 30; x += 40) {
        c.drawCircle(Offset(x, t.top - 18), 4, ring);
      }
    },
  ),
  ForumCardTemplate(
    id: '书摘',
    onPanel: true,
    inset: const EdgeInsets.fromLTRB(16, 44, 16, 16),
    behind: (c, p, t) {
      final panel = RRect.fromRectAndRadius(
        Rect.fromLTRB(t.left - 14, t.top - 36, t.right + 14, t.bottom + 22),
        const Radius.circular(10),
      );
      c.drawRRect(panel, Paint()..color = p.panel);
      c.drawRRect(
        panel,
        Paint()
          ..color = p.decoration
          ..style = PaintingStyle.stroke,
      );
    },
    front: (c, p, t) {
      final quote = TextPainter(
        text: TextSpan(
          text: '“',
          style: TextStyle(
            color: p.accent,
            fontSize: 44,
            height: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      quote.paint(c, Offset(t.left - 4, t.top - 38));
      quote.dispose();
      // Left side: the page number sits bottom-right.
      c.drawLine(
        Offset(t.left, t.bottom + 10),
        Offset(t.left + 44, t.bottom + 10),
        Paint()
          ..color = p.accent
          ..strokeWidth = 2,
      );
    },
  ),
  ForumCardTemplate(
    id: '光影',
    inset: const EdgeInsets.only(top: 8),
    behind: (c, p, t) {
      c.drawRect(
        _page,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            const Offset(forumCardWidth, forumCardHeight),
            [
              Color.lerp(p.background, p.dark ? p.accent : Colors.white, .22)!,
              p.background,
            ],
          ),
      );
      final light = Paint()
        ..color = (p.dark ? p.accent : Colors.white).withValues(
          alpha: p.dark ? .08 : .35,
        );
      for (final (a, b) in [(150.0, 250.0), (270.0, 330.0)]) {
        c.drawPath(
          Path()
            ..moveTo(a, 0)
            ..lineTo(b, 0)
            ..lineTo(forumCardWidth, b * .9)
            ..lineTo(forumCardWidth, a * .9)
            ..close(),
          light,
        );
      }
    },
  ),
  ForumCardTemplate(
    id: '简约',
    inset: const EdgeInsets.all(8),
    front: (c, p, t) {
      final frame = Paint()
        ..color = p.decoration
        ..style = PaintingStyle.stroke;
      c.drawRect(const Rect.fromLTWH(10, 10, 340, 460), frame);
      c.drawRect(const Rect.fromLTWH(14, 14, 332, 452), frame);
    },
  ),
  ForumCardTemplate(
    id: '涂鸦',
    inset: const EdgeInsets.symmetric(vertical: 10),
    front: (c, p, t) {
      final pen = Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final wave = Path()..moveTo(t.left, forumCardHeight - 14);
      for (var x = t.left; x < t.left + 120; x += 12) {
        wave.relativeQuadraticBezierTo(3, -5, 6, 0);
        wave.relativeQuadraticBezierTo(3, 5, 6, 0);
      }
      c.drawPath(wave, pen);
      c.drawCircle(const Offset(334, 22), 8, pen);
      c.drawCircle(const Offset(318, 34), 3, Paint()..color = p.decoration);
    },
  ),
  ForumCardTemplate(
    id: '涂写',
    inset: const EdgeInsets.only(top: 14),
    front: (c, p, t) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(t.left - 4, t.top - 20, 120, 9),
          const Radius.circular(5),
        ),
        Paint()..color = p.decoration,
      );
    },
  ),
  const ForumCardTemplate(id: '纯文字'),
];

ForumCardTemplate forumCardTemplate(String id) => forumCardTemplates
    .firstWhere((t) => t.id == id, orElse: () => forumCardTemplates.first);

const forumCardWeights = <String, FontWeight>{
  '常规': FontWeight.w400,
  '中粗': FontWeight.w600,
  '粗体': FontWeight.w700,
};

/// Template + base colour + text settings. Dimensions are logical pixels.
class ForumCardStyle {
  String template = '基础', font = 'system', weight = '常规';
  Color background = const Color(0xfff5ecdc);
  Color? requestedText;
  double size = 20, line = 1.55, spacing = 0, margin = 24;
  TextAlign align = TextAlign.left;

  ForumCardTemplate get design => forumCardTemplate(template);
  ForumCardPalette get palette => ForumCardPalette.from(background);

  /// The user's colour when it stays readable (WCAG AA) on the surface the
  /// text sits on; otherwise the palette's generated text colour.
  Color get textColor {
    final p = palette;
    final surface = design.onPanel ? p.panel : p.background;
    if (requestedText != null &&
        forumCardContrast(requestedText!, surface) >= 4.5) {
      return requestedText!;
    }
    return p.text;
  }

  TextStyle get textStyle => TextStyle(
    color: textColor,
    fontSize: size,
    height: line,
    letterSpacing: spacing,
    fontWeight: forumCardWeights[weight] ?? FontWeight.w400,
    fontFamily: font == 'source' ? 'SourceHanSans' : null,
  );

  Map<String, dynamic> toJson() => {
    'template': template,
    'font': font,
    'weight': weight,
    'background': background.toARGB32(),
    'text': requestedText?.toARGB32(),
    'size': size,
    'line': line,
    'spacing': spacing,
    'margin': margin,
    'align': align.name,
  };
  static ForumCardStyle fromJson(Map<String, dynamic> j) {
    double n(String k, double fallback, double min, double max) =>
        j[k] is num ? (j[k] as num).toDouble().clamp(min, max) : fallback;
    final s = ForumCardStyle();
    if (forumCardTemplates.any((t) => t.id == j['template'])) {
      s.template = j['template'] as String;
    }
    s.font = j['font'] == 'source' ? 'source' : 'system';
    if (forumCardWeights.containsKey(j['weight'])) {
      s.weight = j['weight'] as String;
    }
    s.background = Color(j['background'] as int? ?? 0xfff5ecdc);
    s.requestedText = j['text'] is int ? Color(j['text']) : null;
    s.size = n('size', 20, 16, 60);
    s.line = n('line', 1.55, 1.1, 2.2);
    s.spacing = n('spacing', 0, 0, 4);
    s.margin = n('margin', 24, 16, 40);
    s.align = TextAlign.values.firstWhere(
      (a) => a.name == j['align'],
      orElse: () => TextAlign.left,
    );
    return s;
  }
}

/// Where text may be drawn on a page: margin + template inset + page footer.
Rect forumCardTextArea(ForumCardStyle style) {
  final inset = style.design.inset;
  return Rect.fromLTRB(
    style.margin + inset.left,
    style.margin + inset.top,
    forumCardWidth - style.margin - inset.right,
    forumCardHeight - style.margin - inset.bottom - _footerHeight,
  );
}

TextPainter forumCardText(String text, ForumCardStyle style) => TextPainter(
  text: TextSpan(text: text, style: style.textStyle),
  textDirection: TextDirection.ltr,
  textAlign: style.align,
)..layout(maxWidth: forumCardTextArea(style).width);

/// A token is a grapheme or a complete Latin word; words are never split.
List<String> paginateForumCard(String text, ForumCardStyle style) {
  final pages = <String>[];
  final available = forumCardTextArea(style).height;
  for (final section in text.split('\f')) {
    if (section.isEmpty) {
      pages.add('');
      continue;
    }
    final tokens = <String>[];
    final pattern = RegExp(
      r'[A-Za-z0-9]+(?:[\x27’_-][A-Za-z0-9]+)*|[^A-Za-z0-9]+',
    );
    for (final match in pattern.allMatches(section)) {
      final value = match.group(0)!;
      if (RegExp(r'^[A-Za-z0-9]').hasMatch(value)) {
        tokens.add(value);
      } else {
        tokens.addAll(value.characters);
      }
    }
    var start = 0;
    while (start < tokens.length) {
      var low = start + 1, high = tokens.length, end = start;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        final painter = forumCardText(tokens.sublist(start, mid).join(), style);
        final fits = painter.height <= available + .01;
        painter.dispose();
        if (fits) {
          end = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (end == start) throw StateError('单个英文词过长，当前页面放不下；请增加边距内可用空间或减小字号。');
      if (end < tokens.length) {
        int lastBoundary(bool paragraph) {
          for (var i = end; i > start; i--) {
            if (paragraph
                ? tokens[i - 1] == '\n'
                : RegExp(r'[。！？；：.!?;:]$').hasMatch(tokens[i - 1])) {
              return i;
            }
          }
          return start;
        }

        final paragraph = lastBoundary(true), sentence = lastBoundary(false);
        if (paragraph > start) {
          end = paragraph;
        } else if (sentence > start) {
          end = sentence;
        }
      }
      pages.add(tokens.sublist(start, end).join());
      start = end;
    }
  }
  return pages.isEmpty ? [''] : pages;
}

void paintForumCard(
  Canvas canvas,
  Size size,
  String text,
  ForumCardStyle style,
  int page,
  int total,
) {
  final palette = style.palette;
  final design = style.design;
  final area = forumCardTextArea(style);
  canvas.save();
  canvas.scale(size.width / forumCardWidth, size.height / forumCardHeight);
  canvas.clipRect(_page);
  canvas.drawRect(_page, Paint()..color = palette.background);
  design.behind?.call(canvas, palette, area);
  final painter = forumCardText(text, style);
  painter.paint(canvas, area.topLeft);
  painter.dispose();
  // Decorations drawn after the text are clipped away from the text area.
  canvas.save();
  canvas.clipPath(
    Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(_page)
      ..addRect(area),
  );
  design.front?.call(canvas, palette, area);
  canvas.restore();
  if (total > 1) {
    final footer = TextPainter(
      text: TextSpan(
        text: '${page + 1} / $total',
        style: TextStyle(
          fontSize: 10,
          color: palette.muted,
          fontFamily: style.textStyle.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    footer.paint(
      canvas,
      Offset(area.right - footer.width, area.bottom + _footerHeight - 13),
    );
    footer.dispose();
  }
  canvas.restore();
}

Future<Uint8List> renderForumCardPage(
  String text,
  ForumCardStyle style,
  int page,
  int total,
) async {
  final recorder = ui.PictureRecorder();
  paintForumCard(
    Canvas(recorder),
    const Size(1080, 1440),
    text,
    style,
    page,
    total,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1080, 1440);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('image_failed');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
