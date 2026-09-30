import 'note_reader.dart';

/// Text-weighted progress, shared by scrolling, seeking and speech snapshots.
class ReaderProgress {
  ReaderProgress(this.paragraphs) {
    for (final paragraph in paragraphs) {
      starts.add(
        starts.last + (paragraph.text.isEmpty ? 1 : paragraph.text.length),
      );
    }
  }
  final List<ReaderParagraph> paragraphs;
  final List<int> starts = [0];
  double fraction(int index, double within) => paragraphs.isEmpty
      ? 0
      : ((starts[index] +
                    within.clamp(0, 1) * (starts[index + 1] - starts[index])) /
                starts.last)
            .clamp(0, 1);

  ({int index, int offset, double within}) position(double fraction) {
    if (paragraphs.isEmpty) return (index: 0, offset: 0, within: 0);
    final target = (fraction.clamp(0, 1) * starts.last).floor();
    var low = 0, high = paragraphs.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (starts[mid] <= target) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final text = paragraphs[low].text;
    var offset = (target - starts[low]).clamp(0, text.length);
    if (offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff) {
      offset--;
    }
    return (
      index: low,
      offset: offset,
      within: text.isEmpty ? 0 : offset / text.length,
    );
  }
}
