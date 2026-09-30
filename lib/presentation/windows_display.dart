import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool get usesWindowsDisplay =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

const windowsDisplaySizes = ['small', 'standard', 'large', 'extraLarge'];
double windowsTextFactor(String size) => switch (size) {
  'small' => .95,
  'standard' => 1,
  'extraLarge' => 1.3,
  _ => 1.15,
};

// Flutter's PerMonitorV2 runner already converts physical pixels to logical
// pixels. Compose with accessibility scaling; never multiply by DPI again.
class _DisplayTextScaler extends TextScaler {
  const _DisplayTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;
  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;
  @override
  double get textScaleFactor => scale(14) / 14;
  @override
  bool operator ==(Object other) =>
      other is _DisplayTextScaler &&
      other.system == system &&
      other.factor == factor;
  @override
  int get hashCode => Object.hash(system, factor);
}

class WindowsDisplay extends StatelessWidget {
  const WindowsDisplay({super.key, required this.size, required this.child});
  final String size;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!usesWindowsDisplay) return child;
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final factor = windowsTextFactor(size);
    final icons = 1 + (factor - 1) * .6;
    return _WindowsDisplayData(
      systemScaler: media.textScaler,
      child: MediaQuery(
        data: media.copyWith(
          textScaler: _DisplayTextScaler(media.textScaler, factor),
        ),
        child: Theme(
          data: theme.copyWith(
            iconTheme: theme.iconTheme.copyWith(size: 24 * icons),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _WindowsDisplayData extends InheritedWidget {
  const _WindowsDisplayData({required this.systemScaler, required super.child});
  final TextScaler systemScaler;
  @override
  bool updateShouldNotify(_WindowsDisplayData oldWidget) =>
      systemScaler != oldWidget.systemScaler;
}

/// Reading surfaces receive extra emphasis without enlarging their padding.
/// The note reader uses its own saved size and only the original system scale.
class WindowsContentText extends StatelessWidget {
  const WindowsContentText({
    super.key,
    required this.child,
    this.independentSize = false,
  });
  final Widget child;
  final bool independentSize;
  @override
  Widget build(BuildContext context) {
    if (!usesWindowsDisplay) return child;
    final media = MediaQuery.of(context);
    final display = context
        .dependOnInheritedWidgetOfExactType<_WindowsDisplayData>();
    return MediaQuery(
      data: media.copyWith(
        textScaler: independentSize
            ? display?.systemScaler ?? media.textScaler
            : _DisplayTextScaler(media.textScaler, 1.1),
      ),
      child: child,
    );
  }
}

double readingPageMaxWidth(double mobileWidth) =>
    usesWindowsDisplay ? double.infinity : mobileWidth;
