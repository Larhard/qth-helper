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

  Future<void> update(double lat, double lon, double altMeters) async {
    try {
      final result = await _channel.invokeMethod<double>(
        'getDeclination',
        {'lat': lat, 'lon': lon, 'alt': altMeters},
      );
      if (result != null) _declination = result;
    } on PlatformException {
      // Leave last known declination in place
    }
  }
}
