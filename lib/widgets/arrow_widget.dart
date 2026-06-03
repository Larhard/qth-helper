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
    final rr = size.width / 2;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(bearingDeg * pi / 180);

    // Compass-needle / chevron arrow: a sharp head pointing "up" (the bearing)
    // with a concave notch at the centre.  Matches the floating-overlay compass.
    const sin140 = 0.6428; // sin(140°)
    const cos140 = -0.7660; // cos(140°)
    final tip  = rr * 0.92;
    final barb = rr * 0.46;
    final path = Path()
      ..moveTo(0, -tip)                              // tip (heading)
      ..lineTo(sin140 * barb, -cos140 * barb)        // right barb (back-right)
      ..lineTo(0, 0)                                 // centre notch
      ..lineTo(-sin140 * barb, -cos140 * barb)       // left barb (back-left)
      ..close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.bearingDeg != bearingDeg || old.color != color;
}
