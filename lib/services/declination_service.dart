import 'package:flutter/services.dart';

/// Wraps Android's GeomagneticField via a platform channel.
/// Returns magnetic declination in degrees (positive = east of true north).
/// True heading = magnetic heading + declination.
class DeclinationService {
  static const _channel = MethodChannel('qth_helper/geomagnetic');

  DeclinationService._();
  static final instance = DeclinationService._();

  double _declination = 0.0;
  double get declination => _declination;

  // Throttle: magnetic declination changes negligibly below ~10 km movement,
  // so one platform-channel call per minute at most.
  int _lastCallMs = 0;
  static const _intervalMs = 60000;

  Future<void> update(double lat, double lon, double altMeters) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCallMs < _intervalMs) return;
    _lastCallMs = now;
    try {
      final result = await _channel.invokeMethod<double>(
        'getDeclination',
        {'lat': lat, 'lon': lon, 'alt': altMeters},
      );
      if (result != null) _declination = result;
    } on PlatformException {
      // Leave last known declination in place.
    }
  }
}
