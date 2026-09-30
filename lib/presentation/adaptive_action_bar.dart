import 'dart:math' as math;
import 'package:flutter/material.dart';

class BarAction {
  const BarAction(
    this.label,
    this.onPressed, {
    this.color,
    this.icon,
    this.visualScale = 1,
  });
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final IconData? icon;
  final double visualScale;
}

/// Allocate the whole row by measured text width, preserving 48dp hit targets.
/// Single-line headers deliberately fit large system text to available width.
class AdaptiveActionBar extends StatelessWidget {
  const AdaptiveActionBar({
    super.key,
    required this.actions,
    required this.menu,
    this.menuIndex,
    this.maxFontSize = 28,
  });
  final List<BarAction> actions;
  final Widget menu;
  final int? menuIndex;
  final double maxFontSize;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context);
      final base = Theme.of(context).textTheme.titleMedium!;
      List<double> widths(double size) => actions.map((a) {
        final p = TextPainter(
          text: TextSpan(
            text: a.label,
            style: base.copyWith(fontSize: size),
          ),
          textScaler: scale,
          textDirection: Directionality.of(context),
          maxLines: 1,
        )..layout();
        return math.max(48.0, p.width + 8);
      }).toList();
      var font = maxFontSize;
      var sizes = widths(font);
      while (sizes.fold<double>(48, (a, b) => a + b) > box.maxWidth &&
          font > 8) {
        font -= .25;
        sizes = widths(font);
      }
      final spare = math.max(
        0.0,
        box.maxWidth - 48 - sizes.fold<double>(0, (a, b) => a + b),
      );
      final children = <Widget>[];
      for (var i = 0; i < actions.length; i++) {
        if (i == (menuIndex ?? actions.length)) {
          children.add(SizedBox(width: 48, height: 48, child: menu));
        }
        final a = actions[i];
        children.add(
          SizedBox(
            width: sizes[i] + spare / actions.length,
            height: math.max(48, scale.scale(font) * 1.4),
            child: a.icon != null
                ? IconButton(
                    tooltip: a.label,
                    onPressed: a.onPressed,
                    iconSize: font * a.visualScale,
                    color: a.color ?? Theme.of(context).colorScheme.onSurface,
                    icon: Icon(a.icon),
                  )
                : TextButton(
                    onPressed: a.onPressed,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 48),
                      foregroundColor:
                          a.color ?? Theme.of(context).colorScheme.onSurface,
                      textStyle: base.copyWith(fontSize: font * a.visualScale),
                    ),
                    child: Text(a.label, maxLines: 1, softWrap: false),
                  ),
          ),
        );
      }
      if ((menuIndex ?? actions.length) == actions.length) {
        children.add(SizedBox(width: 48, height: 48, child: menu));
      }
      return Row(children: children);
    },
  );
}
