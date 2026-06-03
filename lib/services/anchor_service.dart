import 'dart:async';
import 'package:flutter/services.dart';
import 'package:get_storage/get_storage.dart';
import '../utils/geo_utils.dart';

enum AnchorAlarmLevel { idle, warning, alarm }

/// Manages anchor alarm state, position checking, and GPS-loss escalation.
///
/// Alarm levels:
///   idle    — inside safe zone (distance < warningFraction × radius)
///   warning — approaching boundary (warningFraction × radius ≤ dist < radius)
///             OR GPS lost 60–180 s
///   alarm   — outside radius OR GPS lost > 180 s
///
/// GPS-loss timings: 60 s → warning, 180 s → alarm.
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

  // ── Anchor state ────────────────────────────────────────────────────────────
  double? _lat, _lon;
  double  _radiusM         = 50.0;
  double  _warningFraction = 0.80; // phase 1 starts at this fraction of radius

  bool _active = false;
  AnchorAlarmLevel _level = AnchorAlarmLevel.idle;
  double? _distanceM;
  double? _bearingDeg; // bearing FROM current position TO anchor

  // Whether the alarm audio/vibration has been silenced by the user (level
  // stays in place so the visual indicators persist until anchor is lifted).
  bool _silenced = false;

  // ── GPS loss tracking ────────────────────────────────────────────────────────
  DateTime? _lastGpsTime;
  Timer?    _gpsLossTimer;
  int       _gpsLossSeconds = 0;
  bool      _gpsLost        = false;

  // ── GPS-on-lock save/restore ─────────────────────────────────────────────────
  bool _prevGpsOnLock = false;

  // ── Notification callback ────────────────────────────────────────────────────
  // Set by _HomeScreenState; called whenever any state changes.
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
  bool             get gpsLost         => _gpsLost;
  int              get gpsLossSeconds  => _gpsLossSeconds;
  bool             get isSilenced      => _silenced;
  bool             get prevGpsOnLock   => _prevGpsOnLock;

  // Warning-zone radius in metres (convenience for UI display).
  double get warningRadiusM => _radiusM * _warningFraction;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  void dropAnchor({
    required double lat,
    required double lon,
    required double radiusM,
    required double warningFraction,
    required bool   prevGpsOnLock,
  }) {
    _lat             = lat;
    _lon             = lon;
    _radiusM         = radiusM;
    _warningFraction = warningFraction;
    _prevGpsOnLock   = prevGpsOnLock;
    _active          = true;
    _level           = AnchorAlarmLevel.idle;
    _silenced        = false;
    _gpsLost         = false;
    _gpsLossSeconds  = 0;
    _lastGpsTime     = DateTime.now();
    _distanceM       = 0.0;
    _bearingDeg      = 0.0;
    _persist();
    _startGpsLossTimer();
    onStateChanged?.call();
  }

  void liftAnchor() {
    _active         = false;
    _level          = AnchorAlarmLevel.idle;
    _silenced       = false;
    _distanceM      = null;
    _bearingDeg     = null;
    _gpsLossSeconds = 0;
    _gpsLost        = false;
    _gpsLossTimer?.cancel();
    _gpsLossTimer   = null;
    _clearPersisted();
    _stopNative();
    onStateChanged?.call();
  }

  // ── Persistence ──────────────────────────────────────────────────────────────

  void _persist() {
    _store.write(_kActive,   true);
    _store.write(_kLat,      _lat);
    _store.write(_kLon,      _lon);
    _store.write(_kRadius,   _radiusM);
    _store.write(_kWarnFrac, _warningFraction);
    _store.write(_kPrevGps,  _prevGpsOnLock);
  }

  void _clearPersisted() {
    _store.remove(_kActive);
    _store.remove(_kLat);
    _store.remove(_kLon);
    _store.remove(_kRadius);
    _store.remove(_kWarnFrac);
    _store.remove(_kPrevGps);
  }

  /// Restore anchor state from storage after the app was killed.
  /// Returns true if an active anchor was found and restored.
  bool loadFromStorage() {
    if (!(_store.read<bool>(_kActive) ?? false)) return false;
    _lat             = _store.read<double>(_kLat);
    _lon             = _store.read<double>(_kLon);
    _radiusM         = _store.read<double>(_kRadius)   ?? 50.0;
    _warningFraction = _store.read<double>(_kWarnFrac) ?? 0.80;
    _prevGpsOnLock   = _store.read<bool>(_kPrevGps)   ?? true;
    _active          = true;
    _level           = AnchorAlarmLevel.idle;
    _silenced        = false;
    _gpsLost         = false;
    _gpsLossSeconds  = 0;
    _lastGpsTime     = DateTime.now();
    _distanceM       = null;
    _bearingDeg      = null;
    _startGpsLossTimer();
    return true;
  }

  /// Called by home_screen on every GPS position update.
  void onPositionUpdate(double lat, double lon) {
    if (!_active) return;
    _lastGpsTime    = DateTime.now();
    _gpsLossSeconds = 0;
    _gpsLost        = false;

    if (_lat == null || _lon == null) return;
    _distanceM  = haversineKm(lat, lon, _lat!, _lon!) * 1000.0;
    _bearingDeg = bearing(lat, lon, _lat!, _lon!);
    _recomputeLevel();
    onStateChanged?.call();
  }

  /// Silence audio/vibration/flash for this alarm cycle.
  /// The alarm LEVEL (visual) persists until the anchor is lifted or the boat
  /// returns inside the safe zone.
  /// Called when battery drops to 10 % while anchoring.
  void triggerBatteryWarning() {
    if (!_active) return;
    if (_level.index < AnchorAlarmLevel.warning.index) {
      _level = AnchorAlarmLevel.warning;
      _applyNativeLevel();
      onStateChanged?.call();
    }
  }

  /// Called when battery drops to 5 % while anchoring.
  void triggerBatteryAlarm() {
    if (!_active) return;
    if (_level != AnchorAlarmLevel.alarm) {
      _unsilence();
      _level = AnchorAlarmLevel.alarm;
      _applyNativeLevel();
      onStateChanged?.call();
    }
  }

  void silenceAlarm() {
    _silenced = true;
    _stopNative();
    onStateChanged?.call();
  }

  /// Unsilence: used when alarm level escalates again.
  void _unsilence() => _silenced = false;

  void updateRadius(double r) {
    _radiusM = r;
    if (_active) _recomputeLevel();
  }

  void updateWarningFraction(double f) {
    _warningFraction = f;
    if (_active) _recomputeLevel();
  }

  // ── Internal ─────────────────────────────────────────────────────────────────

  void _recomputeLevel() {
    final d = _distanceM;
    if (d == null) return;

    AnchorAlarmLevel position =
        d >= _radiusM         ? AnchorAlarmLevel.alarm
      : d >= warningRadiusM   ? AnchorAlarmLevel.warning
                              : AnchorAlarmLevel.idle;

    AnchorAlarmLevel gpsLoss =
        _gpsLossSeconds >= 180 ? AnchorAlarmLevel.alarm
      : _gpsLossSeconds >= 60  ? AnchorAlarmLevel.warning
                               : AnchorAlarmLevel.idle;

    // Highest level wins.
    final newLevel = _max(position, gpsLoss);

    if (newLevel.index > _level.index) {
      // Escalation: unsilence so the new level can sound.
      _unsilence();
    }

    if (newLevel != _level) {
      _level = newLevel;
      _applyNativeLevel();
    }
  }

  void _applyNativeLevel() {
    if (_silenced) return;
    switch (_level) {
      case AnchorAlarmLevel.idle:    _stopNative();
      case AnchorAlarmLevel.warning: _ch.invokeMethod('startWarning').catchError((_) {});
      case AnchorAlarmLevel.alarm:   _ch.invokeMethod('startAlarm').catchError((_) {});
    }
  }

  void _stopNative() => _ch.invokeMethod('stopAlarm').catchError((_) {});

  void _startGpsLossTimer() {
    _gpsLossTimer?.cancel();
    _gpsLossTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_active) return;
      final last = _lastGpsTime;
      if (last == null) return;
      _gpsLossSeconds = DateTime.now().difference(last).inSeconds;
      _gpsLost        = _gpsLossSeconds >= 10; // small grace period for GNSS hiccups
      _recomputeLevel();
      onStateChanged?.call();
    });
  }

  static AnchorAlarmLevel _max(AnchorAlarmLevel a, AnchorAlarmLevel b) =>
      a.index >= b.index ? a : b;
}
