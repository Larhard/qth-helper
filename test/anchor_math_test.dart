import 'package:flutter_test/flutter_test.dart';
import 'package:qth_dashboard/utils/anchor_math.dart';

/// Tests for the safety-critical anchor alarm level logic.
///
/// This is the most important test file in the project: a regression here could
/// mean a dragging anchor goes unannounced.  Every threshold and the "highest
/// level wins" rule is covered.
void main() {
  group('AnchorMath.compute — distance thresholds', () {
    const radius = 50.0;
    const warn = 0.80; // warning zone starts at 40 m

    AnchorAlarmLevel at(double? d, {int loss = 0, int batt = 0}) =>
        AnchorMath.compute(
          distanceM: d, radiusM: radius, warnFraction: warn,
          gpsLossSeconds: loss, batteryFloor: batt,
        );

    test('well inside the safe zone is idle', () {
      expect(at(0), AnchorAlarmLevel.idle);
      expect(at(20), AnchorAlarmLevel.idle);
      expect(at(39.9), AnchorAlarmLevel.idle);
    });

    test('at the warning boundary becomes warning', () {
      expect(at(40), AnchorAlarmLevel.warning);   // exactly warnFrac*radius
      expect(at(45), AnchorAlarmLevel.warning);
      expect(at(49.9), AnchorAlarmLevel.warning);
    });

    test('at or beyond the radius becomes alarm', () {
      expect(at(50), AnchorAlarmLevel.alarm);     // exactly radius
      expect(at(80), AnchorAlarmLevel.alarm);
      expect(at(500), AnchorAlarmLevel.alarm);
    });

    test('no fix (null distance) does not raise a position alarm by itself', () {
      expect(at(null), AnchorAlarmLevel.idle);
    });
  });

  group('AnchorMath.compute — GPS-loss escalation', () {
    AnchorAlarmLevel loss(int s) => AnchorMath.compute(
          distanceM: 0, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: s,
        );

    test('fresh / brief loss is idle', () {
      expect(loss(0), AnchorAlarmLevel.idle);
      expect(loss(59), AnchorAlarmLevel.idle);
    });

    test('60 s loss escalates to warning', () {
      expect(loss(60), AnchorAlarmLevel.warning);
      expect(loss(120), AnchorAlarmLevel.warning);
      expect(loss(179), AnchorAlarmLevel.warning);
    });

    test('180 s loss escalates to alarm', () {
      expect(loss(180), AnchorAlarmLevel.alarm);
      expect(loss(600), AnchorAlarmLevel.alarm);
    });
  });

  group('AnchorMath.compute — highest level wins', () {
    test('position idle but GPS lost → GPS level applies', () {
      expect(
        AnchorMath.compute(
            distanceM: 0, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: 200),
        AnchorAlarmLevel.alarm,
      );
    });

    test('position alarm but GPS fresh → alarm', () {
      expect(
        AnchorMath.compute(
            distanceM: 99, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: 0),
        AnchorAlarmLevel.alarm,
      );
    });

    test('battery floor raises an otherwise-idle state', () {
      expect(
        AnchorMath.compute(
            distanceM: 0, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: 0,
            batteryFloor: 1),
        AnchorAlarmLevel.warning,
      );
      expect(
        AnchorMath.compute(
            distanceM: 0, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: 0,
            batteryFloor: 2),
        AnchorAlarmLevel.alarm,
      );
    });

    test('battery floor never lowers a higher position level', () {
      expect(
        AnchorMath.compute(
            distanceM: 99, radiusM: 50, warnFraction: 0.8, gpsLossSeconds: 0,
            batteryFloor: 1),
        AnchorAlarmLevel.alarm,
      );
    });
  });

  group('AnchorMath.compute — configurable warning fraction', () {
    test('a tighter warning fraction widens the warning zone', () {
      // warnFrac 0.5 → warning begins at 25 m of a 50 m radius.
      expect(
        AnchorMath.compute(
            distanceM: 30, radiusM: 50, warnFraction: 0.5, gpsLossSeconds: 0),
        AnchorAlarmLevel.warning,
      );
    });

    test('a 1000 m radius (large vessel) scales thresholds', () {
      AnchorAlarmLevel at(double d) => AnchorMath.compute(
          distanceM: d, radiusM: 1000, warnFraction: 0.8, gpsLossSeconds: 0);
      expect(at(700), AnchorAlarmLevel.idle);
      expect(at(800), AnchorAlarmLevel.warning);
      expect(at(1000), AnchorAlarmLevel.alarm);
    });
  });
}
