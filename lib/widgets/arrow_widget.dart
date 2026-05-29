import 'package:flutter/material.dart';
import 'dart:math';

class ArrowWidget extends StatelessWidget {
  final double bearingDeg;
  final Color color;
  final double size;

  const ArrowWidget({
    super.key,
    required this.bearingDeg,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ArrowPainter(bearingDeg: bearingDeg, color: color)),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final double bearingDeg;
  final Color color;

  _ArrowPainter({required this.bearingDeg, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 * 0.88;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(bearingDeg * pi / 180);

    // Arrow pointing up: wide triangle head + slim rectangular shaft
    final path = Path()
      ..moveTo(0, -r)
      ..lineTo(r * 0.33, -r * 0.18)
      ..lineTo(r * 0.12, -r * 0.18)
      ..lineTo(r * 0.12, r * 0.78)
      ..lineTo(-r * 0.12, r * 0.78)
      ..lineTo(-r * 0.12, -r * 0.18)
      ..lineTo(-r * 0.33, -r * 0.18)
      ..close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.bearingDeg != bearingDeg || old.color != color;
}
