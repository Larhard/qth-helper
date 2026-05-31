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

/// Human-readable elapsed duration, two levels of granularity:
///   < 60 s   → "42s"
///   < 60 min → "5m 30s"   (seconds component omitted when zero)
///   < 24 h   → "3h 15m"   (minutes component omitted when zero)
///   1 d +    → "2d 11h"   (hours component omitted when zero)
String formatElapsed(Duration d) {
  final s = d.inSeconds.abs();
  if (s < 60) return '${s}s';
  final m = d.inMinutes.abs();
  if (m < 60) {
    final remS = s % 60;
    return remS > 0 ? '${m}m ${remS}s' : '${m}m';
  }
  final h = d.inHours.abs();
  if (h < 24) {
    final remM = m % 60;
    return remM > 0 ? '${h}h ${remM}m' : '${h}h';
  }
  final days = d.inDays.abs();
  final remH = h % 24;
  return remH > 0 ? '${days}d ${remH}h' : '${days}d';
}

const _timeUtcKey = 'time_utc';
bool loadTimeUtc() => GetStorage().read<bool>(_timeUtcKey) ?? true;
void saveTimeUtc(bool v) => GetStorage().write(_timeUtcKey, v);

// ── Coordinate format ──────────────────────────────────────────────────────

enum CoordFormat { degMinDec, degDec, degMinSec }

const _coordFmtKey = 'coord_format';
CoordFormat loadCoordFormat() {
  final idx = GetStorage().read<int>(_coordFmtKey) ?? 0;
  return CoordFormat.values[idx.clamp(0, CoordFormat.values.length - 1)];
}
void saveCoordFormat(CoordFormat f) => GetStorage().write(_coordFmtKey, f.index);

// ── Locator type ───────────────────────────────────────────────────────────

enum LocatorType { maidenhead, mgrs }

const _locTypeKey = 'locator_type';
LocatorType loadLocatorType() {
  final idx = GetStorage().read<int>(_locTypeKey) ?? 0;
  return LocatorType.values[idx.clamp(0, LocatorType.values.length - 1)];
}
void saveLocatorType(LocatorType t) => GetStorage().write(_locTypeKey, t.index);
