import 'package:flutter/material.dart' show Color;
import 'package:get_storage/get_storage.dart';

// ── Night-mode colour palette ─────────────────────────────────────────────
// All entries share hue ≈ 0° (pure red family).  Vary only in lightness so
// every dark-mode screen has a cohesive, easily-distinguished palette.
// Use these constants in every screen instead of raw Color literals so that
// a single edit here updates the whole app.
const kN0    = Color(0xFFFF3333); // brightest  — emergency / destructive
const kN1    = Color(0xFFCC1111); // primary    — main text, active icons
const kN2    = Color(0xFF9A1111); // secondary  — labels, sub-icons
const kN3    = Color(0xFF771111); // tertiary   — metadata, captions
const kN4    = Color(0xFF4A1111); // very dim   — hints, disabled
const kNBg   = Color(0xFF1A0000); // tile / card background
const kNDiv  = Color(0xFF250505); // dividers, borders
const kNSheet= Color(0xFF0A0000); // modal / bottom-sheet background

// ── Day-mode colour palette ───────────────────────────────────────────────
// Each semantic category gets its own hue for clarity; sub-text / label
// variants use the same hue family but darker.  Unlike the night palette
// (single hue, varying brightness), day uses colour as a data-type signal.
// All kD* constants replace raw Color literals throughout the app.

// Neutral text hierarchy (on dark panel surfaces)
const kDFg0  = Color(0xFFFFFFFF); // primary   — headings, primary values
const kDFg1  = Color(0xFFEEEEEE); // secondary — sub-values
const kDFg2  = Color(0xFFCCCCCC); // tertiary  — speed, altitude, accuracy
const kDFg3  = Color(0xFF888888); // dim       — labels, inactive icons
const kDFg4  = Color(0xFF666666); // very dim  — hints, disabled text

// Heading / GPS — green family (also: IARU locator, UTC clock, north marker)
const kDGps  = Color(0xFF55DD55); // GPS heading · IARU locator · UTC time
const kDGpsL = Color(0xFF3DBF3D); // GPS / locator sub-label

// TRK (smoothed track bearing) — yellow-green
const kDTrk  = Color(0xFF88CC33);

// Emergency / MOB — red family
const kDEmg  = Color(0xFFFF3333); // MOB name, arrow, highlight
const kDEmgS = Color(0xFFDD3333); // MOB coordinates (softer red)
const kDEmgBg= Color(0xFFB71C1C); // MOB card background

// Stale / warning indicator — orange-red
const kDStale= Color(0xFFFF7043);

// Navigation waypoint — deep-orange family
const kDNav  = Color(0xFFFF6E40); // nav waypoint name / arrow
const kDNavL = Color(0xFFFF8F00); // nav waypoint sub-text / label

// MGRS · local time · amber accents — orange-amber family
const kDAmb  = Color(0xFFFFA726); // MGRS value, local time, save-lock
const kDAmbs = Color(0xFFE65100); // MGRS label, local-time label, large-city sub

// City location tiers
const kDCityL = Color(0xFFFF9800); // large city — orange
const kDCityP = Color(0xFFFFD740); // precise city — amber (also: warnings)
const kDCityD = Color(0xFFC6FF00); // detailed city — lime
const kDCityDS= Color(0xFFAEEA00); // detailed city sub — lime-dark

// Port / water features — cyan family
const kDPort  = Color(0xFF00E5FF); // port name, live-lock badge
const kDPortL = Color(0xFF00ACC1); // port sub-text, live-lock label

// UI chrome (on the app's dark-panel surface)
const kDDiv    = Color(0xFF1A1A1A); // dividers, separators
const kDBrd    = Color(0xFF333333); // input / tile borders
const kDFoc    = Color(0xFF555555); // focused input border
const kDSheetBg= Color(0xFF111111); // modal / bottom-sheet background
const kDSnackBg= Color(0xFF1C1C1C); // floating snackbar background

// Maidenhead locator precision tiers (debug / locator display only)
const kDGpsM6  = Color(0xFF69F0AE); // 6-char Maidenhead (~12 km)
const kDGpsM4  = Color(0xFF80CBC4); // 4-char Maidenhead (field)

// Emergency card border ring — shown during hold-to-clear animation
const kDEmgRing    = Color(0xFF4A1515); // day: active progress ring
const kDEmgRingDim = Color(0xFF3D1212); // day: idle ring
const kNEmgRing    = Color(0xFF2A0A0A); // night: active progress ring
const kNEmgRingDim = Color(0xFF1A0808); // night: idle ring
const kDEmgArc     = Color(0xFFFF6666); // day: arc animation end colour
const kNEmgArc     = Color(0xFFAA3333); // night: arc animation end colour

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

// ── Heading arrow display mode ─────────────────────────────────────────────
// arrow    = simple rotating arrow + relative dots (mode A)
// windRose = compass rose rotating around the arrow (mode B)

enum HeadingArrowMode { arrow, windRose }

const _arrowModeKey = 'heading_arrow_mode';
HeadingArrowMode loadHeadingArrowMode() {
  final idx = GetStorage().read<int>(_arrowModeKey) ?? 0;
  return HeadingArrowMode.values[idx.clamp(0, HeadingArrowMode.values.length - 1)];
}
void saveHeadingArrowMode(HeadingArrowMode m) =>
    GetStorage().write(_arrowModeKey, m.index);

// ── Heading source mode ────────────────────────────────────────────────────
// magOnly = compass always primary  (TRK/GPS secondary)
// auto    = GPS when fast, TRK when medium speed, MAG when slow (MAG secondary)

enum HeadingSourceMode { magOnly, auto }

const _sourceModeKey = 'heading_source_mode';
HeadingSourceMode loadHeadingSourceMode() {
  final idx = GetStorage().read<int>(_sourceModeKey) ?? 0;
  return HeadingSourceMode.values[idx.clamp(0, HeadingSourceMode.values.length - 1)];
}
void saveHeadingSourceMode(HeadingSourceMode m) =>
    GetStorage().write(_sourceModeKey, m.index);
