import 'package:flutter_test/flutter_test.dart';
import 'package:qth_dashboard/utils/geo_utils.dart';

void main() {
  group('haversineKm', () {
    test('zero distance for identical points', () {
      expect(haversineKm(50.0, 19.0, 50.0, 19.0), closeTo(0.0, 1e-9));
    });

    test('one degree of latitude is ~111 km', () {
      final d = haversineKm(0, 0, 1, 0);
      expect(d, closeTo(111.19, 0.5));
    });

    test('known city pair Kraków → Warsaw is ~250 km', () {
      // Kraków 50.0647,19.9450 → Warsaw 52.2297,21.0122
      final d = haversineKm(50.0647, 19.9450, 52.2297, 21.0122);
      expect(d, closeTo(252, 5));
    });

    test('is symmetric', () {
      final ab = haversineKm(50.0, 19.0, 52.0, 21.0);
      final ba = haversineKm(52.0, 21.0, 50.0, 19.0);
      expect(ab, closeTo(ba, 1e-9));
    });

    test('short anchor-scale distance ~10 m for ~0.0001° latitude', () {
      final d = haversineKm(50.0, 19.0, 50.0001, 19.0) * 1000.0; // metres
      expect(d, closeTo(11.1, 0.5));
    });
  });

  group('bearing', () {
    test('due north is ~0°', () {
      expect(bearing(0, 0, 1, 0), closeTo(0, 0.5));
    });

    test('due east is ~90°', () {
      expect(bearing(0, 0, 0, 1), closeTo(90, 0.5));
    });

    test('due south is ~180°', () {
      expect(bearing(1, 0, 0, 0), closeTo(180, 0.5));
    });

    test('due west is ~270°', () {
      expect(bearing(0, 1, 0, 0), closeTo(270, 0.5));
    });

    test('always within [0, 360)', () {
      for (final p in [
        [50.0, 19.0, 52.0, 21.0],
        [52.0, 21.0, 50.0, 19.0],
        [-33.0, 151.0, 35.0, 139.0],
      ]) {
        final b = bearing(p[0], p[1], p[2], p[3]);
        expect(b, greaterThanOrEqualTo(0));
        expect(b, lessThan(360));
      }
    });
  });

  group('formatDistance', () {
    test('sub-kilometre shows metres', () => expect(formatDistance(0.42), '420 m'));
    test('mid-range shows one decimal km', () => expect(formatDistance(12.34), '12.3 km'));
    test('large shows rounded km', () => expect(formatDistance(254.6), '255 km'));
  });
}
