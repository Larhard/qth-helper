import 'package:flutter/services.dart';
import 'package:get_storage/get_storage.dart';
import '../utils/anchor_math.dart';

export '../utils/anchor_math.dart' show AnchorAlarmLevel;

/// Foreground presenter for the anchor alarm.
///
/// The single source of truth for level computation and hardware is the native
/// [AnchorController] / [AnchorMonitorService].  This Dart class:
///   • holds the persisted anchor configuration (so the UI knows radius etc.),
///   • mirrors the live snapshot polled from native (for display only),
///   • starts/stops the background service and persists config across kills.
///
/// It does NOT drive the alarm hardware directly — that would create a second
/// authority and the dual-instance audio conflict that field testing exposed.
class AnchorService {
  AnchorService._();
  static final instance = AnchorService._();

  static const _ch    = MethodChannel('qth_helper/anchor_alarm');
  static final _store = GetStorage();

  // ── Persistence keys ────────────────────────────────────────────────────────
  static const _kActive   = 'anchor_active';
  static const _kLat      = 'anchor_lat';
  static const _kLon      = 'anchor_lon';
  static const _kRadius   = 'anchor_radius';
  static const _kWarnFrac = 'anchor_warn_frac';
  static const _kPrevGps  = 'anchor_prev_gps';

  // ── Configuration (persisted) ────────────────────────────────────────────────
  double? _lat, _lon;
  double  _radiusM         = 50.0;
  double  _warningFraction = 0.80;
  bool    _active          = false;
  bool    _prevGpsOnLock   = false;

  // ── Live snapshot (polled from native) ───────────────────────────────────────
  AnchorAlarmLevel _level = AnchorAlarmLevel.idle;
  double? _distanceM;
  double? _bearingDeg;
  int     _gpsLossSeconds = 0;
  bool    _silenced       = false;
  bool    _hasFix         = false;

  /// Called by the UI whenever the polled snapshot changes.
  void Function()? onStateChanged;

  // ── Getters ─────────────────────────────────────────────────────────────────
  bool             get isActive        => _active;
  double?          get distanceM       => _distanceM;
  double?          get bearingDeg      => _bearingDeg;
  double           get radiusM         => _radiusM;
  double           get warningFraction => _warningFraction;
  double?          get anchorLat       => _lat;
  double?          get anchorLon       => _lon;
  AnchorAlarmLevel get level           => _level;
  bool             get gpsLost         => _gpsLossSeconds >= 10;
  int              get gpsLossSeconds  => _gpsLossSeconds;
  bool             get isSilenced      => _silenced;
  bool             get hasFix          => _hasFix;
  bool             get prevGpsOnLock   => _prevGpsOnLock;
  double           get warningRadiusM  => _radiusM * _warningFraction;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  void dropAnchor({
    required double lat,
    required double lon,
    required double radiusM,
    required double warningFraction,
    required bool   prevGpsOnLock,
  }) {
    _lat = lat; _lon = lon;
    _radiusM = radiusM; _warningFraction = warningFraction;
    _prevGpsOnLock = prevGpsOnLock;
    _active = true;
    _level = AnchorAlarmLevel.idle;
    _silenced = false; _hasFix = false;
    _gpsLossSeconds = 0; _distanceM = 0.0; _bearingDeg = 0.0;
    _persist();
    onStateChanged?.call();
  }

  void liftAnchor() {
    _active = false;
    _level = AnchorAlarmLevel.idle;
    _silenced = false; _hasFix = false;
    _distanceM = null; _bearingDeg = null; _gpsLossSeconds = 0;
    _clearPersisted();
    onStateChanged?.call();
  }

  /// Restore configuration after the app was killed.  Returns true if an
  /// anchor was active.  The live snapshot is then re-synced via [refresh].
  bool loadFromStorage() {
    if (!(_store.read<bool>(_kActive) ?? false)) return false;
    _lat = _store.read<double>(_kLat);
    _lon = _store.read<double>(_kLon);
    _radiusM = _store.read<double>(_kRadius) ?? 50.0;
    _warningFraction = _store.read<double>(_kWarnFrac) ?? 0.80;
    _prevGpsOnLock = _store.read<bool>(_kPrevGps) ?? true;
    _active = true;
    _level = AnchorAlarmLevel.idle;
    _silenced = false; _hasFix = false;
    _gpsLossSeconds = 0; _distanceM = null; _bearingDeg = null;
    return true;
  }

  // ── Native bridge ─────────────────────────────────────────────────────────────

  /// Poll the native authority for the current alarm snapshot.
  /// Called once per second by the home screen while anchoring, and on resume.
  Future<void> refresh() async {
    if (!_active) return;
    final Map? s;
    try {
      s = await _ch.invokeMethod<Map>('getAnchorSnapshot');
    } catch (_) { return; }
    if (s == null) return;

    final lvl = (s['level'] as int? ?? 0).clamp(0, 2);
    _level          = AnchorAlarmLevel.values[lvl];
    _distanceM      = (s['distanceM'] as num?)?.toDouble();
    _bearingDeg     = (s['bearingDeg'] as num?)?.toDouble();
    _gpsLossSeconds = (s['gpsLossSeconds'] as int?) ?? 0;
    _silenced       = (s['silenced'] as bool?) ?? false;
    _hasFix         = (s['hasFix'] as bool?) ?? false;
    onStateChanged?.call();
  }

  /// Forward a (reliable, fused) foreground GPS fix to the native authority so
  /// the GPS-loss timer is reset by the most reliable source available.
  void forwardPosition(double lat, double lon) {
    if (!_active) return;
    _ch.invokeMethod('forwardPosition', {'lat': lat, 'lon': lon}).catchError((_) {});
  }

  void silenceAlarm() {
    _silenced = true;
    _ch.invokeMethod('silenceAnchor').catchError((_) {});
    onStateChanged?.call();
  }

  void escalateBattery(int floor) {
    if (!_active) return;
    _ch.invokeMethod('escalateBattery', {'floor': floor}).catchError((_) {});
  }

  // ── Persistence helpers ───────────────────────────────────────────────────────

  void _persist() {
    _store.write(_kActive, true);
    _store.write(_kLat, _lat);
    _store.write(_kLon, _lon);
    _store.write(_kRadius, _radiusM);
    _store.write(_kWarnFrac, _warningFraction);
    _store.write(_kPrevGps, _prevGpsOnLock);
  }

  void _clearPersisted() {
    for (final k in [_kActive, _kLat, _kLon, _kRadius, _kWarnFrac, _kPrevGps]) {
      _store.remove(k);
    }
  }
}
