import 'package:flutter/material.dart';

/// Shared "－ [slider] ＋" control: a Slider with fine-adjustment buttons
/// tight against its own ends, so it adds no row height versus a plain
/// Slider. Used for every adjustable reader setting (speed, font size,
/// brightness, line spacing, letter spacing) and for the reading/TTS
/// progress bar, so the -/+ behavior is implemented once.
///
/// [onChangeStart]/[onChangeEnd] are optional and only needed by a caller
/// that, like the progress bar, must pause/resume something around a seek;
/// plain instant-apply sliders can leave them out.
class StepperSlider extends StatelessWidget {
  const StepperSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.enabled = true,
    this.sliderKey,
  });
  final double value, min, max, step;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final bool enabled;
  /// Key applied to the inner [Slider] rather than this wrapper, for callers
  /// (and their widget tests) that look up the slider directly.
  final Key? sliderKey;

  void _nudge(double delta) {
    final next = (value + delta).clamp(min, max);
    if (next == value) return;
    onChangeStart?.call(value);
    onChanged(next);
    onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        tooltip: '减少',
        onPressed: enabled && value > min ? () => _nudge(-step) : null,
        icon: const Icon(Icons.remove, size: 18),
      ),
      Expanded(
        child: Slider(
          key: sliderKey,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: enabled ? onChanged : null,
          onChangeStart: enabled ? onChangeStart : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        tooltip: '增加',
        onPressed: enabled && value < max ? () => _nudge(step) : null,
        icon: const Icon(Icons.add, size: 18),
      ),
    ],
  );
}
