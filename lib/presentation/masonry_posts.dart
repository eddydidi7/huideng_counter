import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Measures each card at its natural height and places it in the shorter column.
/// The surrounding feed owns scrolling; this widget never stretches cards.
class MasonryPosts extends MultiChildRenderObjectWidget {
  const MasonryPosts({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _MasonryRender();
}

class _MasonryData extends ContainerBoxParentData<RenderBox> {}

class _MasonryRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MasonryData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MasonryData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MasonryData) child.parentData = _MasonryData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final columnWidth = (width - 8) / 2;
    final heights = <double>[0, 0];
    var child = firstChild;
    while (child != null) {
      child.layout(
        BoxConstraints.tightFor(width: columnWidth),
        parentUsesSize: true,
      );
      final column = heights[0] <= heights[1] ? 0 : 1;
      final data = child.parentData! as _MasonryData;
      data.offset = Offset(column * (columnWidth + 8), heights[column]);
      heights[column] += child.size.height;
      child = data.nextSibling;
    }
    size = constraints.constrain(
      Size(width, heights[0] > heights[1] ? heights[0] : heights[1]),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
