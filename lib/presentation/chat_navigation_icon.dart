import 'package:flutter/material.dart';

/// Compact green double-bubble mark for the chat destination.
class ChatNavigationIcon extends StatelessWidget {
  const ChatNavigationIcon({
    super.key,
    this.selected = false,
    this.size = 21.6,
  });

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _ChatMarkPainter(selected)),
  );
}

class _ChatMarkPainter extends CustomPainter {
  const _ChatMarkPainter(this.selected);
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final green = Paint()
      ..color = selected ? const Color(0xFF07C160) : const Color(0xFF2BAE66);
    canvas.drawOval(const Rect.fromLTWH(0, 2, 17, 14), green);
    canvas.drawPath(
      Path()
        ..moveTo(3, 12)
        ..lineTo(2, 18)
        ..lineTo(8, 15)
        ..close(),
      green,
    );
    final white = Paint()..color = Colors.white;
    canvas.drawCircle(const Offset(5.5, 7.5), 1, white);
    canvas.drawCircle(const Offset(11.5, 7.5), 1, white);
    canvas.drawOval(const Rect.fromLTWH(8, 9, 16, 13), white);
    canvas.drawOval(const Rect.fromLTWH(9, 10, 14, 11), green);
    canvas.drawPath(
      Path()
        ..moveTo(18, 19)
        ..lineTo(23, 23)
        ..lineTo(21, 17)
        ..close(),
      green,
    );
    canvas.drawCircle(const Offset(13, 14), 0.9, white);
    canvas.drawCircle(const Offset(18.5, 14), 0.9, white);
  }

  @override
  bool shouldRepaint(_ChatMarkPainter oldDelegate) =>
      selected != oldDelegate.selected;
}
