import 'package:get_storage/get_storage.dart';

enum SpeedUnit { metric, nautical, imperial }

const _speedUnitKey = 'speed_unit';

SpeedUnit loadSpeedUnit() {
  final idx = GetStorage().read<int>(_speedUnitKey) ?? 0;
  return SpeedUnit.values[idx.clamp(0, SpeedUnit.values.length - 1)];
}

void saveSpeedUnit(SpeedUnit u) => GetStorage().write(_speedUnitKey, u.index);

String formatSpeed(double ms, SpeedUnit unit) {
  switch (unit) {
    case SpeedUnit.metric:
      final v = ms * 3.6;
      if (v < 0.5) return '0.0 km/h';
      return v < 10 ? '${v.toStringAsFixed(1)} km/h' : '${v.round()} km/h';
    case SpeedUnit.nautical:
      final v = ms * 1.94384;
      if (v < 0.3) return '0.0 kn';
      return v < 10 ? '${v.toStringAsFixed(1)} kn' : '${v.round()} kn';
    case SpeedUnit.imperial:
      final v = ms * 2.23694;
      if (v < 0.5) return '0.0 mph';
      return v < 10 ? '${v.toStringAsFixed(1)} mph' : '${v.round()} mph';
  }
}

String formatDistanceUnit(double km, SpeedUnit unit) {
  switch (unit) {
    case SpeedUnit.metric:
      if (km < 1.0) return '${(km * 1000).round()} m';
      if (km < 100.0) return '${km.toStringAsFixed(1)} km';
      return '${km.round()} km';
    case SpeedUnit.nautical:
      final nm = km * 0.539957;
      if (nm < 0.05) return '${(nm * 1852).round()} m';
      if (nm < 10.0) return '${nm.toStringAsFixed(2)} nm';
      if (nm < 100.0) return '${nm.toStringAsFixed(1)} nm';
      return '${nm.round()} nm';
    case SpeedUnit.imperial:
      final mi = km * 0.621371;
      if (mi < 0.1) return '${(mi * 5280).round()} ft';
      if (mi < 10.0) return '${mi.toStringAsFixed(2)} mi';
      if (mi < 100.0) return '${mi.toStringAsFixed(1)} mi';
      return '${mi.round()} mi';
  }
}

// Altitude: metric → metres, nautical/imperial → feet (aviation standard).
String formatAlt(double m, SpeedUnit unit) {
  if (unit == SpeedUnit.metric) return '${m.round()} m';
  return '${(m * 3.28084).round()} ft';
}

String speedUnitLabel(SpeedUnit unit) {
  switch (unit) {
    case SpeedUnit.metric:   return 'METRIC';
    case SpeedUnit.nautical: return 'NAUTICAL';
    case SpeedUnit.imperial: return 'IMPERIAL';
  }
}
