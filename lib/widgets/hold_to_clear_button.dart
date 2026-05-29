import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Round button that must be held for [holdDuration] before firing [onConfirmed].
/// A circular progress ring fills during the hold and rewinds on release.
class HoldToClearButton extends StatefulWidget {
  final VoidCallback onConfirmed;
  final Duration holdDuration;

  const HoldToClearButton({
    super.key,
    required this.onConfirmed,
    this.holdDuration = const Duration(seconds: 3),
  });

  @override
  State<HoldToClearButton> createState() => _HoldToClearButtonState();
}

class _HoldToClearButtonState extends State<HoldToClearButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.holdDuration)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _ctrl.reset();
          HapticFeedback.heavyImpact();
          widget.onConfirmed();
        }
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _start(LongPressStartDetails _) => _ctrl.forward();

  void _cancel() {
    // Snap back quickly — duration proportional to how far it filled.
    final snapMs = (_ctrl.value * 400).round() + 80;
    _ctrl.animateTo(0,
        duration: Duration(milliseconds: snapMs), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: _start,
      onLongPressEnd: (_) => _cancel(),
      onLongPressCancel: _cancel,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => SizedBox(
          width: 60,
          height: 60,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(
              value: _ctrl.value,
              color: const Color(0xFFFF5252),
              backgroundColor: const Color(0xFF2A0A0A),
              strokeWidth: 3.5,
            ),
            const Text(
              'HOLD\nCLEAR',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF884444),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                height: 1.4,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
