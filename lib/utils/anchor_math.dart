/// Pure anchor-alarm level logic — the canonical, unit-tested specification.
///
/// IMPORTANT: the Kotlin `AnchorController.recompute()` MUST replicate these
/// exact thresholds, because the background service has to evaluate the level
/// without the Flutter engine.  Any change here requires the same change in
/// `android/.../AnchorController.kt`.
library;

enum AnchorAlarmLevel { idle, warning, alarm }

class AnchorMath {
  AnchorMath._();

  /// GPS-loss escalation timings (seconds).
  static const gpsWarningSeconds = 60;
  static const gpsAlarmSeconds   = 180;

  /// Compute the alarm level from the current facts.
  ///
  /// [distanceM]      — metres from the anchor (null if no fix yet).
  /// [radiusM]        — configured alarm radius.
  /// [warnFraction]   — fraction of radius at which the warning zone begins.
  /// [gpsLossSeconds] — seconds since the last fix.
  /// [batteryFloor]   — minimum level forced by low battery (0/1/2).
  static AnchorAlarmLevel compute({
    required double? distanceM,
    required double radiusM,
    required double warnFraction,
    required int gpsLossSeconds,
    int batteryFloor = 0,
  }) {
    final position = distanceM == null
        ? AnchorAlarmLevel.idle // no fix → defer to the GPS-loss timer
        : distanceM >= radiusM
            ? AnchorAlarmLevel.alarm
            : distanceM >= radiusM * warnFraction
                ? AnchorAlarmLevel.warning
                : AnchorAlarmLevel.idle;

    final gpsLoss = gpsLossSeconds >= gpsAlarmSeconds
        ? AnchorAlarmLevel.alarm
        : gpsLossSeconds >= gpsWarningSeconds
            ? AnchorAlarmLevel.warning
            : AnchorAlarmLevel.idle;

    final floor = AnchorAlarmLevel.values[batteryFloor.clamp(0, 2)];

    return _max(_max(position, gpsLoss), floor);
  }

  static AnchorAlarmLevel _max(AnchorAlarmLevel a, AnchorAlarmLevel b) =>
      a.index >= b.index ? a : b;
}
