import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import '../utils/track_bearing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:get_storage/get_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../models/waypoint.dart';
import '../services/city_service.dart';
import '../services/declination_service.dart';
import '../services/waypoint_service.dart';
import '../utils/coordinate_utils.dart';
import '../utils/geo_utils.dart';
import '../utils/mgrs_utils.dart';
import '../utils/units.dart';
import '../widgets/arrow_widget.dart';
import 'debug_screen.dart';
import 'waypoints_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Constants ─────────────────────────────────────────────────────────────
  static const _gpsThresholdMs = 1.5;    // m/s ≈ 5.4 km/h
  static const _compassIntervalMs = 100; // ~10 Hz — slightly lower than before
  static const _cityRecalcThresholdM = 100.0;

  // ── GPS / compass streams ─────────────────────────────────────────────────
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // ── GPS state ─────────────────────────────────────────────────────────────
  Position? _position;
  double? _lastValidGpsHeading;
  NearestCity? _nearestCity;
  Position? _lastCityCalcPos;
  String? _error;

  // Cached display strings — updated in GPS listener, read in build.
  // Avoids re-running formatLat/formatLon/maidenhead on every widget rebuild.
  String _cachedLatStr = '';
  String _cachedLonStr = '';
  String _cachedLocStr = '';
  double _cachedAlt = 0;
  double _cachedAccuracy = 0;

  // ── Compass state ─────────────────────────────────────────────────────────
  double _compassHeading = 0;
  bool _compassReceived = false;
  int _lastCompassMs = 0;
  // ValueNotifier drives the secondary arrow directly, bypassing setState batching.
  final _compassNotifier = ValueNotifier<double>(0.0);

  // ── Track azimuth ─────────────────────────────────────────────────────────
  // ── Track azimuth ─────────────────────────────────────────────────────────
  final _track = TrackBearingEstimator();

  // ── GPS staleness ─────────────────────────────────────────────────────────
  Timer? _staleTimer;
  DateTime _lastGpsFix = DateTime.now();
  int _gpsStaleSeconds = 0; // 0 = fresh; > 0 = seconds since last fix

  // True while the screen is on (resumed lifecycle). Used to skip wasted
  // display work and city lookups when the GPS fires in LIVE mode background.
  bool _screenOn = true;
  // Last compass heading that actually triggered a setState — used to suppress
  // rebuilds when the heading hasn't changed enough to matter visually.
  double _lastRenderedCompassHeading = -1.0;

  // ── Speed unit ────────────────────────────────────────────────────────────
  SpeedUnit _speedUnit = loadSpeedUnit();

  // ── Time display ──────────────────────────────────────────────────────────
  bool _timeUtc = loadTimeUtc();
  // Offset from system clock to GPS time, updated on every GPS fix.
  // DateTime.now() + _gpsClockOffset gives a GPS-calibrated current time
  // that ticks in real time between fixes.
  Duration _gpsClockOffset = Duration.zero;

  // ── Coordinate / locator format ────────────────────────────────────────────
  CoordFormat _coordFormat = loadCoordFormat();
  LocatorType _locatorType = loadLocatorType();

  // ── MOB hold-to-clear ─────────────────────────────────────────────────────
  // Driven by a real Stopwatch — immune to ticker mute/unmute jumps.
  static const _holdToClearMs = 3000;
  static const _rewindPerFrame = 0.05;
  late final Ticker _holdTicker;
  final Stopwatch _holdWatch = Stopwatch();
  bool _holding = false;
  double _clearProgress = 0.0;

  // ── GPS-on-lock mode ───────────────────────────────────────────────────────
  // When false (default) the GPS stream is cancelled on screen-off to save
  // battery. When true, the stream keeps running so TRK stays live and the
  // first glance after unlock shows fresh data instantly.
  static const _toggleHoldMs = 1500;
  static const _toggleRewindPerFrame = 0.08;
  bool _gpsOnLock = false;
  late final Ticker _toggleTicker;
  final Stopwatch _toggleWatch = Stopwatch();
  bool _toggling = false;
  double _toggleProgress = 0.0;

  // ── Day / Night mode ──────────────────────────────────────────────────────
  // Day  : full-contrast palette — readable in direct sunlight.
  // Night: red-only palette — preserves rhodopsin (night-vision accommodation)
  //        by emitting only long-wavelength light.  No greens, blues, or ambers.
  bool _dayMode = GetStorage().read<bool>('day_mode') ?? true;

  // ── Night palette target: 4 levels of dim red, no other colours ─────────────
  //   Primary   0xFFCC3333  — main data (heading degrees, coordinates)
  //   Secondary 0xFF882222  — supporting (speed, city name, bearing, MOB name)
  //   Tertiary  0xFF661111  — labels (source, TRK, alt/acc, hints)
  //   Ghost     0xFF441111  — barely-there (dividers, secondary arrow, borders)

  // Text hierarchy
  Color get _cText1 => _dayMode ? Colors.white                : const Color(0xFFCC3333);
  Color get _cText2 => _dayMode ? const Color(0xFFEEEEEE)     : const Color(0xFF882222);
  Color get _cText3 => _dayMode ? const Color(0xFFCCCCCC)     : const Color(0xFF661111);
  // Element-specific
  Color get _cSpeed   => _dayMode ? const Color(0xFFD8D8D8)   : const Color(0xFF882222);
  Color get _cAltAcc  => _dayMode ? const Color(0xFFCCCCCC)   : const Color(0xFF882222); // bumped from 551111
  Color get _cStale   => _dayMode ? const Color(0xFFFF7043)   : const Color(0xFFCC2222);
  // IARU locator now green (matches GPS arrow + UTC clock) — freed cyan goes to port
  Color get _cLocator => _dayMode ? const Color(0xFF55DD55)   : const Color(0xFF882222);
  Color get _cLocatorLabel => _dayMode ? const Color(0xFF3DBF3D) : const Color(0xFF661111);
  Color get _cMgrs    => _dayMode ? const Color(0xFFFFA726)   : const Color(0xFF882222);
  Color get _cMgrsLabel => _dayMode ? const Color(0xFFE65100) : const Color(0xFF661111);
  Color get _cTime    => _dayMode
      ? (_timeUtc ? const Color(0xFF55DD55) : const Color(0xFFFFB74D))
      : const Color(0xFF882222);
  Color get _cTimeLabel => _dayMode
      ? (_timeUtc ? const Color(0xFF3DBF3D) : const Color(0xFFE65100))
      : const Color(0xFF661111);
  // GPS-lock toggle indicator
  Color get _cSaveLock => _dayMode ? const Color(0xFFFFAB40) : const Color(0xFF661111);
  Color get _cLiveLock => _dayMode ? const Color(0xFF26C6DA) : const Color(0xFF992222);
  // Secondary heading arrow — ghost level in night (no extra Opacity needed)
  Color get _cSecondaryArrow => _dayMode ? Colors.white : const Color(0xFF441111);
  // Active waypoint / MOB card
  Color get _cWptName   => _dayMode ? const Color(0xFFFF3333) : const Color(0xFF882222);
  Color get _cWptArrow  => _dayMode ? const Color(0xFFFF3333) : const Color(0xFF882222);
  Color get _cWptData   => _dayMode ? const Color(0xFFFF2020) : const Color(0xFF771111);
  Color get _cWptCoords => _dayMode ? const Color(0xFFDD3333) : const Color(0xFF882222); // brighter in both
  Color get _cWptHint   => _dayMode ? const Color(0xFF4A1A1A) : const Color(0xFF441111);
  // MOB button (emergency button — always visible but dimmer at night)
  Color get _cMobBg   => _dayMode ? const Color(0xFFB71C1C) : const Color(0xFF661111);
  Color get _cMobText => _dayMode ? Colors.white              : const Color(0xFFCC3333);

  void _toggleDayMode() {
    HapticFeedback.mediumImpact();
    setState(() => _dayMode = !_dayMode);
    GetStorage().write('day_mode', _dayMode);
    _showSettingSnack(_dayMode
        ? 'Day mode — full brightness'
        : 'Night mode — red only, preserves night vision');
  }

  // ── Derived ───────────────────────────────────────────────────────────────
  bool get _usingGps {
    final p = _position;
    return p != null && p.speed >= _gpsThresholdMs && !p.heading.isNaN && p.heading >= 0;
  }

  double get _heading => _usingGps ? _position!.heading : _compassHeading;

  // In night mode both GPS and compass arrows use dim red; no greens or whites.
  Color get _headingColor => _dayMode
      ? (_usingGps ? const Color(0xFF55DD55) : Colors.white)
      : (_usingGps ? const Color(0xFFCC2222) : const Color(0xFF882222));

  Color get _secondaryHeadingColor => _dayMode ? Colors.white : const Color(0xFF882222);

  // City accent colours collapse to dim red in night mode.
  Color get _cityColor => !_dayMode ? const Color(0xFF882222) : switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFFF9800),  // orange   — global overview
    CityMode.precise  => const Color(0xFFFFD740),  // amber    — regional
    CityMode.detailed => const Color(0xFFC6FF00),  // lime     — local detail
    CityMode.port     => const Color(0xFF00E5FF),  // nautical cyan (freed from IARU)
  };
  Color get _citySubColor => !_dayMode ? const Color(0xFF551111) : switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFE65100),  // deep orange
    CityMode.precise  => const Color(0xFFFFAB40),  // light amber
    CityMode.detailed => const Color(0xFFAEEA00),  // darker lime
    CityMode.port     => const Color(0xFF00ACC1),  // darker cyan sub-text
  };

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holdTicker = createTicker(_onHoldTick);
    _toggleTicker = createTicker(_onToggleTick);
    _gpsOnLock = GetStorage().read<bool>('gps_on_lock') ?? false;
    _staleTimer = Timer.periodic(const Duration(seconds: 1), _onStaleTick);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTicker.dispose();
    _toggleTicker.dispose();
    _compassNotifier.dispose();
    _posSub?.cancel();
    _compassSub?.cancel();
    _staleTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _screenOn = false;
      // Screen off → release every continuously-running power draw:
      //  • compass sensor (paused)
      //  • GNSS receiver (stream cancelled — the big saving on long hikes)
      //  • 1 Hz stale timer (cancelled — no point waking the CPU for hidden UI)
      _compassSub?.pause();
      _staleTimer?.cancel();
      _staleTimer = null;
      _cancelClear();
      _cancelToggle();
      if (_gpsOnLock) {
        // Switch to a foreground-service-backed stream. Android throttles GPS
        // for background apps without a foreground service (API 26+); keeping
        // the plain stream subscription alive does not prevent this.
        _startPositionStreamBackground();
      } else {
        _posSub?.cancel();
        _posSub = null;
      }
    } else if (state == AppLifecycleState.resumed) {
      _screenOn = true;
      _compassSub?.resume();
      _staleTimer ??= Timer.periodic(const Duration(seconds: 1), _onStaleTick);
      // Always restart the normal (no notification) stream on resume, whether
      // coming from SAVE (null sub) or LIVE (background foreground-service sub).
      _startPositionStream();
      _requestImmediateGpsFix();
    }
  }

  void _requestImmediateGpsFix() {
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).then((pos) {
      if (!mounted) return;
      _lastGpsFix = DateTime.now();
      _cachedLatStr = formatLatF(pos.latitude, _coordFormat);
      _cachedLonStr = formatLonF(pos.longitude, _coordFormat);
      _cachedLocStr = _locStr(pos.latitude, pos.longitude);
      _cachedAlt = pos.altitude;
      _cachedAccuracy = pos.accuracy;
      _gpsClockOffset = pos.timestamp.difference(DateTime.now());
      setState(() {
        _position = pos;
        _gpsStaleSeconds = 0;
      });
    }).catchError((_) {});
  }

  // ── GPS staleness timer ────────────────────────────────────────────────────
  void _onStaleTick(Timer _) {
    if (!mounted) return;
    final sec = DateTime.now().difference(_lastGpsFix).inSeconds;
    // Always rebuild on every tick: the time row needs a fresh DateTime.now()
    // each second. The cost is one setState per second while the screen is on;
    // the timer is cancelled when the screen turns off.
    if (sec != _gpsStaleSeconds) setState(() => _gpsStaleSeconds = sec);
  }

  // ── Stream init ───────────────────────────────────────────────────────────
  Future<void> _init() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() =>
            _error = 'Location permission required.\nEnable it in Settings.');
      }
      return;
    }

    _startPositionStream();

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastCompassMs < _compassIntervalMs) return;
      _lastCompassMs = now;
      final corrected =
          (h + DeclinationService.instance.declination + 360) % 360;
      _compassHeading = corrected;
      _compassNotifier.value = corrected;
      if (!_compassReceived) _compassReceived = true;
      // Only rebuild when the heading has changed enough to be visible.
      // Suppresses ~10 Hz redraws when stationary (compass jitter ±0.5°).
      if (!_usingGps && mounted) {
        final delta = (corrected - _lastRenderedCompassHeading).abs();
        final wrapped = delta > 180 ? 360 - delta : delta; // handle 359°→1° wrap
        if (wrapped >= 0.5) {
          _lastRenderedCompassHeading = corrected;
          setState(() {});
        }
      }
    });
  }

  // The position stream is cancelled when the screen turns off (see lifecycle
  // handler) and recreated here on resume, so the GNSS receiver isn't draining
  // power during long screen-off stretches on a hike.
  // Shared handler — called from both the normal (foreground) and background
  // (foreground-service) GPS streams.
  void _onPositionUpdate(Position pos) {
    _lastGpsFix = DateTime.now();
    if (_gpsStaleSeconds > 0) _gpsStaleSeconds = 0;

    // GPS course is usable above ~0.5 m/s; cache at lower threshold so the
    // secondary arrow appears even at walking pace.
    if (pos.speed >= 0.5 && !pos.heading.isNaN && pos.heading >= 0) {
      _lastValidGpsHeading = pos.heading;
    }

    // Track bearing and declination run in both foreground and background —
    // they are the primary benefit of LIVE mode (fresh TRK on unlock).
    _updateTrackBearing(pos);
    DeclinationService.instance.update(pos.latitude, pos.longitude, pos.altitude);

    if (!_screenOn || !mounted) {
      // Screen is off (LIVE mode background stream): skip all display work.
      // String formatting, city lookups, and setState are wasted CPU when
      // nothing is visible. Cache the raw position for display on resume.
      // NOTE: !mounted also guards against rare widget-disposal races.
      _position = pos;
      return;
    }

    // Foreground: update display caches and rebuild.
    _cachedLatStr = formatLatF(pos.latitude, _coordFormat);
    _cachedLonStr = formatLonF(pos.longitude, _coordFormat);
    _cachedLocStr = _locStr(pos.latitude, pos.longitude);
    _cachedAlt = pos.altitude;
    _cachedAccuracy = pos.accuracy;
    _gpsClockOffset = pos.timestamp.difference(DateTime.now());

    final needsCity = _lastCityCalcPos == null ||
        Geolocator.distanceBetween(
              _lastCityCalcPos!.latitude, _lastCityCalcPos!.longitude,
              pos.latitude, pos.longitude,
            ) >= _cityRecalcThresholdM;

    if (needsCity) {
      _lastCityCalcPos = pos;
      final city = CityService.instance.nearest(pos.latitude, pos.longitude);
      setState(() { _position = pos; _nearestCity = city; });
    } else {
      setState(() => _position = pos);
    }
  }

  void _startPositionStream() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen(_onPositionUpdate, onError: (_) {});
  }

  // Foreground-service-backed stream for LIVE mode while the screen is off.
  // Android silently stops GPS for background apps (API 26+) unless a
  // foreground service is running. The persistent notification is mandatory
  // by Android; it disappears when the screen turns on and the normal stream
  // resumes. No extra permissions needed — foreground services with location
  // type are exempt from ACCESS_BACKGROUND_LOCATION.
  void _startPositionStreamBackground() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'QTH Helper',
          notificationText: 'GPS tracking active',
          enableWakeLock: true,
        ),
      ),
    ).listen(_onPositionUpdate, onError: (_) {});
  }

  // ── Track azimuth ─────────────────────────────────────────────────────────
  void _updateTrackBearing(Position pos) {
    _track.update(pos.latitude, pos.longitude);
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  void _addWaypoint() {
    final pos = _position;
    if (pos == null) return;
    HapticFeedback.heavyImpact();
    WaypointService.instance.add(pos.latitude, pos.longitude);
    setState(() {});
  }

  void _deactivateWaypoint() {
    WaypointService.instance.deactivate();
    if (mounted) setState(() {});
  }

  void _startClear() {
    if (WaypointService.instance.active == null) return;
    _holding = true;
    _holdWatch..reset()..start();
    if (!_holdTicker.isActive) _holdTicker.start();
  }

  void _cancelClear() {
    _holding = false;
    _holdWatch..stop()..reset();
    if (_clearProgress > 0 && !_holdTicker.isActive) _holdTicker.start();
  }

  void _onHoldTick(Duration _) {
    if (_holding) {
      final elapsed = _holdWatch.elapsedMilliseconds;
      final p = (elapsed / _holdToClearMs).clamp(0.0, 1.0);
      if (p != _clearProgress) setState(() => _clearProgress = p);
      if (elapsed >= _holdToClearMs) _finishClear();
    } else {
      final next = (_clearProgress - _rewindPerFrame).clamp(0.0, 1.0);
      setState(() => _clearProgress = next);
      if (next <= 0.0) _holdTicker.stop();
    }
  }

  void _finishClear() {
    _holding = false;
    _holdWatch..stop()..reset();
    _holdTicker.stop();
    setState(() => _clearProgress = 0.0);
    HapticFeedback.heavyImpact();
    _deactivateWaypoint();
  }

  // ── GPS-on-lock toggle ────────────────────────────────────────────────────
  void _startToggle() {
    _toggling = true;
    _toggleWatch..reset()..start();
    if (!_toggleTicker.isActive) _toggleTicker.start();
  }

  void _cancelToggle() {
    _toggling = false;
    _toggleWatch..stop()..reset();
    if (_toggleProgress > 0 && !_toggleTicker.isActive) _toggleTicker.start();
  }

  void _onToggleTick(Duration _) {
    if (_toggling) {
      final p = (_toggleWatch.elapsedMilliseconds / _toggleHoldMs).clamp(0.0, 1.0);
      if (p != _toggleProgress) setState(() => _toggleProgress = p);
      if (_toggleWatch.elapsedMilliseconds >= _toggleHoldMs) _finishToggle();
    } else {
      final next = (_toggleProgress - _toggleRewindPerFrame).clamp(0.0, 1.0);
      setState(() => _toggleProgress = next);
      if (next <= 0.0) _toggleTicker.stop();
    }
  }

  void _finishToggle() {
    _toggling = false;
    _toggleWatch..stop()..reset();
    _toggleTicker.stop();
    HapticFeedback.lightImpact();
    // Reset progress ring immediately so it doesn't stay filled during the
    // async permission request that may follow.
    setState(() => _toggleProgress = 0.0);

    if (!_gpsOnLock) {
      // Enabling LIVE mode: background location permission is required on
      // Android 10+ even when a foreground service is running — Android
      // enforces the background location check once the screen is locked.
      _enableLiveModeWithPermission();
    } else {
      setState(() => _gpsOnLock = false);
      GetStorage().write('gps_on_lock', false);
      _showSettingSnack('GPS on screen lock: OFF\nGPS pauses when screen is off — saves battery');
    }
  }

  Future<void> _enableLiveModeWithPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always) {
      perm = await Geolocator.requestPermission();
    }
    if (!mounted) return;
    if (perm == LocationPermission.always) {
      setState(() => _gpsOnLock = true);
      GetStorage().write('gps_on_lock', true);
      _showSettingSnack('GPS on screen lock: ON\nGPS keeps tracking when screen is off');
    } else {
      // Permission denied: stay off and tell the user what to do.
      _showSettingSnack(
        'Background location required.\nGrant "Allow all the time" in app Settings to enable GPS on lock screen.',
      );
    }
  }

  void _showSettingSnack(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 2500),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  String _locStr(double lat, double lon) =>
      _locatorType == LocatorType.maidenhead ? maidenhead(lat, lon) : mgrs(lat, lon);

  void _toggleCoordFormat() {
    final next = CoordFormat.values[(_coordFormat.index + 1) % CoordFormat.values.length];
    final pos = _position;
    setState(() {
      _coordFormat = next;
      if (pos != null) {
        _cachedLatStr = formatLatF(pos.latitude, next);
        _cachedLonStr = formatLonF(pos.longitude, next);
      }
    });
    saveCoordFormat(next);
    HapticFeedback.lightImpact();
  }

  void _toggleLocatorType() {
    final next = _locatorType == LocatorType.maidenhead
        ? LocatorType.mgrs
        : LocatorType.maidenhead;
    final pos = _position;
    setState(() {
      _locatorType = next;
      if (pos != null) _cachedLocStr = _locStr(pos.latitude, pos.longitude);
    });
    saveLocatorType(next);
    HapticFeedback.lightImpact();
  }

  void _toggleTimeZone() {
    setState(() => _timeUtc = !_timeUtc);
    saveTimeUtc(_timeUtc);
    HapticFeedback.lightImpact();
  }

  /// Returns the largest font size ≤ [maxSize] at which [text] fits inside
  /// [maxWidth] in at most [maxLines] lines.
  ///
  /// Uses TextPainter for exact measurement, so no unnecessary shrinkage occurs:
  /// names that already fit in 2 lines at [maxSize] are returned unchanged.
  /// Never returns less than [minSize].
  static double _fitFontSize(
    String text,
    double maxWidth, {
    double maxSize = 32,
    double minSize = 18,
    int maxLines = 2,
    FontWeight weight = FontWeight.w700,
  }) {
    if (maxWidth <= 0 || text.isEmpty) return maxSize;
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: maxSize, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final lines = tp.computeLineMetrics().length;
    if (lines <= maxLines) return maxSize;
    return (maxSize * maxLines / lines).clamp(minSize, maxSize);
  }

  static String _staleDuration(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final rem = s % 60;
    return rem > 0 ? '${m}m ${rem}s' : '${m}m';
  }

  static String _fmtDate(DateTime dt, bool utc) {
    final d = utc ? dt.toUtc() : dt.toLocal();
    return '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
  }

  static String _fmtTime(DateTime dt, bool utc) {
    final d = utc ? dt.toUtc() : dt.toLocal();
    return '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}:${d.second.toString().padLeft(2,'0')}';
  }

  void _cycleSpeedUnit() {
    final next =
        SpeedUnit.values[(_speedUnit.index + 1) % SpeedUnit.values.length];
    setState(() => _speedUnit = next);
    saveSpeedUnit(next);
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(speedUnitLabel(next),
          style: const TextStyle(color: Colors.white60, fontSize: 13)),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 900),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  void _toggleCityMode() {
    CityService.instance.toggleMode();
    _lastCityCalcPos = null;
    final pos = _position;
    if (pos != null) {
      final city = CityService.instance.nearest(pos.latitude, pos.longitude);
      setState(() => _nearestCity = city);
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text,
          style: const TextStyle(color: Colors.white60, fontSize: 13),
          maxLines: 2),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 1200),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  Future<void> _openWaypoints() async {
    _cancelClear(); // reset any in-progress hold
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => WaypointsScreen(
          currentPosition: _position,
          speedUnit: _speedUnit,
          coordFormat: _coordFormat,
          locatorType: _locatorType,
          timeUtc: _timeUtc,
          dayMode: _dayMode,
        ),
      ),
    );
    if (changed == true && mounted) setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildError(_error!);
    if (_position == null) return _buildWaiting();
    return _buildMain();
  }

  Widget _buildWaiting() => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Show compass heading while GPS is still acquiring.
            if (_compassReceived) ...[
              SizedBox(
                width: 80,
                height: 80,
                child: Stack(alignment: Alignment.center, children: [
                  ArrowWidget(bearingDeg: _compassHeading, color: Colors.white, size: 80),
                ]),
              ),
              const SizedBox(height: 6),
              Text('${_compassHeading.round()}°',
                  style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.0)),
              const Text('MAG',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 12, letterSpacing: 2.5)),
              const SizedBox(height: 32),
            ],
            const CircularProgressIndicator(color: Colors.white24),
            const SizedBox(height: 20),
            const Text('Acquiring GPS…',
                style: TextStyle(color: Colors.white38, fontSize: 18)),
          ]),
        ),
      );

  Widget _buildError(String msg) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 18)),
          ),
        ),
      );

  Widget _buildMain() {
    final pos = _position!;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            isLandscape ? _buildLandscape(pos) : _buildPortrait(pos),
            // Waypoints — 48 × 48 hit area, icon visually at top-right corner.
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                onTap: _openWaypoints,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, right: 6),
                      child: Icon(
                        Icons.pin_drop_outlined,
                        size: 22,
                        color: _dayMode
                            ? const Color(0xFF888888)
                            : const Color(0xFF661111),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Debug screen — hold to open; deliberate action required.
            // GestureDetector instead of IconButton: IconButton's Tooltip
            // widget intercepts long-press to show tooltip text, so the
            // onLongPress callback never fires when a tooltip is set.
            // HitTestBehavior.opaque: transparent padding area responds to touches.
            // 48 px minimum touch target matches Material spec and IconButton default.
            Positioned(
              top: 0,
              left: 0,
              child: GestureDetector(
                onLongPress: _openDebug,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, left: 6),
                      child: Icon(
                        Icons.bug_report_outlined,
                        size: 22,
                        color: _dayMode ? const Color(0xFF444444) : const Color(0xFF441111),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Day / Night toggle — hold required (accidental switch during night
            // sailing would be dangerous).  Placed immediately left of waypoints.
            Positioned(
              top: 0,
              right: 48,
              child: GestureDetector(
                onLongPress: _toggleDayMode,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, right: 6),
                      child: Icon(
                        _dayMode ? Icons.nightlight_round : Icons.wb_sunny_outlined,
                        size: 22,
                        color: _dayMode
                            ? const Color(0xFF888888)
                            : const Color(0xFF882222),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortrait(Position pos) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _headingSection(pos),
          _divider(),
          _coordsSection(),
          _divider(),
          if (_nearestCity != null) _citySection(_nearestCity!),
          const Spacer(),
          _wptSection(pos),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ── Landscape layout ─────────────────────────────────────────────────────
  //
  // Left column  (fixed 252 dp): heading (arrow + degrees + speed + source)
  //                              + compact divider
  //                              + coordinates (lat / lon / locator / alt / time)
  //
  // Right column (Expanded):     city section
  //                              + compact divider
  //                              + active waypoint card / MOB button
  //
  // This split gives each section enough vertical room without stacking
  // everything into a single column that overflows on short landscape screens.
  // Font sizes are stepped down ~15 % from portrait — legible without
  // constantly shrinking with each new feature.
  Widget _buildLandscape(Position pos) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      // CrossAxisAlignment.stretch gives the right column the same height as the
      // Scaffold body so Spacer can pin the MOB section to the bottom.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Left: navigation data (40 % of available width) ──────────
          // Flexible flex values scale proportionally on any screen size.
          Flexible(
            flex: 4,
            fit: FlexFit.tight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _headingSectionLandscape(pos),
                _dividerCompact(),
                _coordsSectionLandscape(),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // ── Right: city at top, MOB pinned to bottom (60 % width) ────
          Flexible(
            flex: 6,
            fit: FlexFit.tight,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: _cDivider, width: 1),
                ),
              ),
              padding: const EdgeInsets.only(left: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  if (_nearestCity != null) ...[
                    _citySectionLandscape(_nearestCity!),
                    _dividerCompact(),
                  ],
                  const Spacer(),
                  _wptSectionLandscape(pos),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color get _cDivider =>
      _dayMode ? const Color(0xFF1A1A1A) : const Color(0xFF2A0000);

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Divider(color: _cDivider, height: 1),
      );

  Widget _dividerCompact() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(color: _cDivider, height: 1),
      );

  // ── Heading ───────────────────────────────────────────────────────────────
  Widget _headingSection(Position pos) {
    final color = _headingColor;
    final primary = _heading;
    return Row(children: [
      SizedBox(
        width: 80,
        height: 80,
        child: Stack(alignment: Alignment.center, children: [
          ValueListenableBuilder<double>(
            valueListenable: _compassNotifier,
            builder: (_, compassBearing, __) {
              final secondaryBearing =
                  _usingGps ? compassBearing : (_track.bearing ?? _lastValidGpsHeading);
              if (secondaryBearing == null) return const SizedBox.shrink();
              return Opacity(
                opacity: 0.38,
                child: ArrowWidget(
                    bearingDeg: secondaryBearing,
                    color: _secondaryHeadingColor,
                    size: 80),
              );
            },
          ),
          ArrowWidget(bearingDeg: primary, color: color, size: 80),
        ]),
      ),
      const SizedBox(width: 20),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${primary.round()}°',
            style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w900,
                color: color,
                height: 1.0)),
        GestureDetector(
          onLongPress: _cycleSpeedUnit,
          child: Text(
            formatSpeed(pos.speed, _speedUnit),
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: _cSpeed,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        _lockModeWidget(sourceFontSize: 14, trkFontSize: 14),
      ]),
    ]);
  }

  // Landscape heading: mirrors the portrait layout (arrow left, text right) so
  // both orientations feel consistent. A fixed-width SizedBox on the degrees
  // text prevents the whole section from shifting when digit count changes
  // (e.g. "9°" → "10°" → "359°"). TRK is always rendered so the row height
  // is stable regardless of whether a bearing is available.
  Widget _headingSectionLandscape(Position pos) {
    final color = _headingColor;
    final primary = _heading;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: Stack(alignment: Alignment.center, children: [
            ValueListenableBuilder<double>(
              valueListenable: _compassNotifier,
              builder: (_, compassBearing, __) {
                final secondaryBearing =
                    _usingGps ? compassBearing : (_track.bearing ?? _lastValidGpsHeading);
                if (secondaryBearing == null) return const SizedBox.shrink();
                // Day: ghost white at 38% opacity.
                // Night: ghost red rendered directly — no extra Opacity
                //        so the dim red isn't darkened further to near-black.
                return _dayMode
                    ? Opacity(
                        opacity: 0.38,
                        child: ArrowWidget(
                            bearingDeg: secondaryBearing,
                            color: _cSecondaryArrow,
                            size: 80),
                      )
                    : ArrowWidget(
                        bearingDeg: secondaryBearing,
                        color: _cSecondaryArrow,
                        size: 80);
              },
            ),
            ArrowWidget(bearingDeg: primary, color: color, size: 80),
          ]),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Fixed width prevents layout shift when "9°" grows to "359°".
            SizedBox(
              width: 120,
              child: Text('${primary.round()}°',
                  textAlign: TextAlign.start,
                  style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: color,
                      height: 1.0)),
            ),
            GestureDetector(
              onLongPress: _cycleSpeedUnit,
              child: Text(
                formatSpeed(pos.speed, _speedUnit),
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: _cSpeed,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            _lockModeWidget(sourceFontSize: 12, trkFontSize: 12),
          ],
        ),
      ],
    );
  }

  // ── GPS lock mode indicator ───────────────────────────────────────────────
  // Shows the current heading source (GPS/MAG) and the GPS-during-lock mode
  // (SAVE / LIVE). Hold for 1.5 s to toggle the mode.
  // Long-press the TRK line to open the debug screen.
  Widget _lockModeWidget({required double sourceFontSize, required double trkFontSize}) {
    final modeColor = _gpsOnLock ? _cLiveLock : _cSaveLock;
    final progressColor = _gpsOnLock ? _cSaveLock : _cLiveLock;
    // Bar covers the source row only (single line height).
    final barHeight = sourceFontSize * 1.6;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Vertical progress bar — always 3 px wide, no layout shift.
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 3,
              height: barHeight,
              child: Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  heightFactor: _toggleProgress,
                  child: Container(color: progressColor),
                ),
              ),
            ),
            // Transparent spacer matching TRK line height so bar doesn't
            // visually float away from the text it belongs to.
            SizedBox(height: trkFontSize * 1.4),
          ],
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Source + lock-mode icon — Listener only here (GPS toggle).
            Listener(
              onPointerDown: (_) => _startToggle(),
              onPointerUp: (_) => _cancelToggle(),
              onPointerCancel: (_) => _cancelToggle(),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_usingGps ? 'GPS' : 'MAG',
                    style: TextStyle(
                        fontSize: sourceFontSize,
                        color: _cText2,
                        letterSpacing: 2.5)),
                const SizedBox(width: 6),
                // [gps_fixed/@/lock] = GPS keeps running through lock screen.
                // [gps_off/@/lock]   = GPS pauses when screen locks.
                // Reading: "GPS [on|off] at screen lock"
                Icon(_gpsOnLock ? Icons.gps_fixed : Icons.gps_off,
                    size: sourceFontSize - 1, color: modeColor),
                Text('@',
                    style: TextStyle(
                        fontSize: sourceFontSize - 2,
                        color: modeColor,
                        height: 1.0)),
                Icon(Icons.lock, size: sourceFontSize - 1, color: modeColor),
              ]),
            ),
            Text(
              _track.bearing != null
                  ? 'TRK ${_track.bearing!.round()}°'
                  : 'TRK ---',
              style: TextStyle(
                  fontSize: trkFontSize,
                  color: _cText3,
                  letterSpacing: 1.5),
            ),
          ],
        ),
      ],
    );
  }

  void _openDebug() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DebugScreen(
        position: _position,
        compassHeading: _compassHeading,
        track: _track,
        coordFormat: _coordFormat,
        locatorType: _locatorType,
        speedUnit: _speedUnit,
        timeUtc: _timeUtc,
        dayMode: _dayMode,
      ),
    ));
  }

  // ── Coordinates ───────────────────────────────────────────────────────────
  Widget _coordsSection() {
    // Coordinates are "medium" priority — smaller than the locator (critical)
    // but bigger than altitude (tertiary). Long-press cycles the format.
    final coordStyle = TextStyle(
      fontSize: 22,
      color: _cText1,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => _copyToClipboard('$_cachedLatStr\n$_cachedLonStr'),
        onLongPress: _toggleCoordFormat,
        behavior: HitTestBehavior.opaque,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_cachedLatStr, style: coordStyle),
          const SizedBox(height: 2),
          Text(_cachedLonStr, style: coordStyle),
        ]),
      ),
      const SizedBox(height: 8),
      _locatorRow(fontSize: 32, letterSpacing: 4.0),
      const SizedBox(height: 6),
      _altAccuracyRow(),
      const SizedBox(height: 3),
      _timeRow(),
    ]);
  }

  Widget _coordsSectionLandscape() {
    final coordStyle = TextStyle(
      fontSize: 22,
      color: _cText1,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => _copyToClipboard('$_cachedLatStr\n$_cachedLonStr'),
        onLongPress: _toggleCoordFormat,
        behavior: HitTestBehavior.opaque,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_cachedLatStr, style: coordStyle),
          const SizedBox(height: 2),
          Text(_cachedLonStr, style: coordStyle),
        ]),
      ),
      const SizedBox(height: 6),
      _locatorRow(fontSize: 24, letterSpacing: 2.5),
      const SizedBox(height: 4),
      _altAccuracyRow(),
      const SizedBox(height: 3),
      _timeRow(fontSize: 15.0),
    ]);
  }

  // Single locator row used by both portrait and landscape coords sections.
  // IARU (green) vs MGRS (amber) — color and label make the type obvious.
  // Long-press toggles the type; tap copies the value.
  Widget _locatorRow({required double fontSize, required double letterSpacing}) {
    final isMaidenhead = _locatorType == LocatorType.maidenhead;
    final locColor = isMaidenhead ? _cLocator : _cMgrs;
    final labelColor = isMaidenhead ? _cLocatorLabel : _cMgrsLabel;
    final locFontSize = isMaidenhead ? fontSize : fontSize * 0.72;
    final locLetterSpacing = isMaidenhead ? letterSpacing : 0.5;
    final label = isMaidenhead ? 'IARU' : 'MGRS';

    return GestureDetector(
      onTap: () => _copyToClipboard(_cachedLocStr),
      onLongPress: _toggleLocatorType,
      behavior: HitTestBehavior.opaque,
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(_cachedLocStr,
            style: TextStyle(
                fontSize: locFontSize,
                color: locColor,
                fontWeight: FontWeight.w700,
                letterSpacing: locLetterSpacing,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: labelColor,
                letterSpacing: 1.5)),
      ]),
    );
  }

  Widget _altAccuracyRow() {
    final stale = _gpsStaleSeconds > 10;
    final altStr = formatAlt(_cachedAlt, _speedUnit);
    final accStr = '±${_cachedAccuracy.round()} m';
    final staleStr = stale ? '  GPS ${_staleDuration(_gpsStaleSeconds)}' : '';
    return Row(children: [
      Text('alt $altStr',
          style: TextStyle(
              fontSize: 14,
              color: _cAltAcc,
              fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(width: 12),
      Text('$accStr$staleStr',
          style: TextStyle(
              fontSize: 14,
              color: stale ? _cStale : _cAltAcc,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }

  Widget _timeRow({double fontSize = 18.0}) {
    // Compute the current GPS-calibrated time on every build.
    // _gpsClockOffset is updated on each GPS fix; between fixes the system
    // clock advances normally, so the display ticks every second in real time.
    // Before the first GPS fix the offset is zero and the system clock is shown.
    final now = DateTime.now().add(_gpsClockOffset);
    final dateStr = _fmtDate(now, _timeUtc);
    final timeStr = _fmtTime(now, _timeUtc);
    final color = _cTime;
    final label = _timeUtc ? 'UTC' : 'LCL';
    final labelColor = _cTimeLabel;
    final labelSize = fontSize >= 16 ? 12.0 : 11.0;
    return GestureDetector(
      onLongPress: _toggleTimeZone,
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        Text(dateStr,
            style: TextStyle(
                fontSize: fontSize,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Text(timeStr,
            style: TextStyle(
                fontSize: fontSize,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w700,
                color: labelColor,
                letterSpacing: 1.5)),
      ]),
    );
  }

  // ── City ──────────────────────────────────────────────────────────────────
  void _showCityDetails(NearestCity nc) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      isScrollControlled: true,
      builder: (_) => _CityDetailSheet(
        nc: nc,
        dayMode: _dayMode,
        position: _position,
        speedUnit: _speedUnit,
        coordFormat: _coordFormat,
        locatorType: _locatorType,
      ),
    );
  }

  Widget _citySection(NearestCity nc) {
    final color = _cityColor;
    final subColor = _citySubColor;
    return GestureDetector(
      onTap: _toggleCityMode,
      onLongPress: () => _showCityDetails(nc),
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        ArrowWidget(bearingDeg: nc.bearingDeg, color: color, size: 60),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LayoutBuilder(builder: (_, bc) {
            final fs = _fitFontSize(nc.city.name, bc.maxWidth, maxSize: 32, minSize: 18);
            return Text(nc.city.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: fs, fontWeight: FontWeight.w700, color: color));
          }),
          Row(children: [
            Text('${nc.bearingDeg.round()}°',
                style: TextStyle(
                    fontSize: 22,
                    color: subColor,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 18),
            Text(formatDistanceUnit(nc.distKm, _speedUnit),
                style: TextStyle(
                    fontSize: 22,
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 14),
            Text(nc.city.country,
                style: TextStyle(
                    fontSize: 14,
                    color: subColor.withValues(alpha: 0.7),
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          if (nc.city.vhf.isNotEmpty)
            GestureDetector(
              onTap: () => _copyToClipboard('VHF ${nc.city.vhf}'),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.radio, size: 14, color: subColor),
                const SizedBox(width: 4),
                Text('VHF ${nc.city.vhf}',
                    style: TextStyle(
                        fontSize: 16,
                        color: color,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5)),
              ]),
            ),
          if (nc.city.callSign.isNotEmpty)
            Text(nc.city.callSign,
                style: TextStyle(
                    fontSize: 14,
                    color: subColor.withValues(alpha: 0.8),
                    letterSpacing: 2.0)),
        ]),
        ),   // Expanded
      ]),
    );
  }

  Widget _citySectionLandscape(NearestCity nc) {
    final color = _cityColor;
    final subColor = _citySubColor;
    return GestureDetector(
      onTap: _toggleCityMode,
      onLongPress: () => _showCityDetails(nc),
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        ArrowWidget(bearingDeg: nc.bearingDeg, color: color, size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: LayoutBuilder(builder: (_, bc) {
                  final fs = _fitFontSize(nc.city.name, bc.maxWidth, maxSize: 28, minSize: 16);
                  return Text(nc.city.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: fs, fontWeight: FontWeight.w700, color: color));
                }),
              ),
              const SizedBox(width: 8),
              Text(nc.city.country,
                  style: TextStyle(
                      fontSize: 14,
                      color: subColor.withValues(alpha: 0.7))),
            ]),
            Row(children: [
              Text('${nc.bearingDeg.round()}°',
                  style: TextStyle(
                      fontSize: 20,
                      color: subColor,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 14),
              Text(formatDistanceUnit(nc.distKm, _speedUnit),
                  style: TextStyle(
                      fontSize: 20,
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ]),
        ),
      ]),
    );
  }

  // ── Active waypoint (MOB) ─────────────────────────────────────────────────
  Widget _wptSection(Position pos) {
    final wp = WaypointService.instance.active;
    if (wp == null) {
      return SizedBox(
        width: double.infinity,
        height: 80,
        child: ElevatedButton(
          onPressed: _addWaypoint,
          style: ElevatedButton.styleFrom(
            backgroundColor: _cMobBg,
            foregroundColor: _cMobText,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            elevation: 0,
          ),
          child: const Text('MOB',
              style: TextStyle(
                  fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 5)),
        ),
      );
    }
    return _wptCard(pos, wp, portrait: true);
  }

  Widget _wptSectionLandscape(Position pos) {
    final wp = WaypointService.instance.active;
    if (wp == null) {
      return SizedBox(
        width: double.infinity,
        height: 70,
        child: ElevatedButton(
          onPressed: _addWaypoint,
          style: ElevatedButton.styleFrom(
            backgroundColor: _cMobBg,
            foregroundColor: _cMobText,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            elevation: 0,
          ),
          child: const Text('MOB',
              style: TextStyle(
                  fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 4)),
        ),
      );
    }
    return _wptCard(pos, wp, portrait: false);
  }

  Widget _wptCard(Position pos, Waypoint wp, {required bool portrait}) {
    final b = bearing(pos.latitude, pos.longitude, wp.lat, wp.lon);
    final d = haversineKm(pos.latitude, pos.longitude, wp.lat, wp.lon);
    final arrowSize = portrait ? 60.0 : 56.0;
    final nameFontSize = portrait ? 20.0 : 18.0;
    final dataFontSize = portrait ? 22.0 : 20.0;
    final coordFontSize = portrait ? 14.0 : 14.0;
    final padding = portrait
        ? const EdgeInsets.fromLTRB(14, 12, 14, 14)
        : const EdgeInsets.fromLTRB(12, 8, 12, 8);

    // Outer Padding ensures the border ring is never clipped by parent bounds.
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Listener(
      onPointerDown: (_) => _startClear(),
      onPointerUp: (_) => _cancelClear(),
      onPointerCancel: (_) => _cancelClear(),
      child: CustomPaint(
        painter: _WptBorderPainter(_clearProgress, dayMode: _dayMode),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Bearing row ─────────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ArrowWidget(
                      bearingDeg: b,
                      color: _cWptArrow,
                      size: arrowSize),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(wp.name,
                              style: TextStyle(
                                  fontSize: nameFontSize,
                                  fontWeight: FontWeight.w900,
                                  color: _cWptName,
                                  letterSpacing: 1.5)),
                        ),
                        Row(children: [
                          Text('${b.round()}°',
                              style: TextStyle(
                                  fontSize: dataFontSize,
                                  color: _cWptData,
                                  fontFeatures: const [FontFeature.tabularFigures()])),
                          const SizedBox(width: 14),
                          Text(formatDistanceUnit(d, _speedUnit),
                              style: TextStyle(
                                  fontSize: dataFontSize,
                                  color: _cWptName,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [FontFeature.tabularFigures()])),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: portrait ? 6 : 4),
              // ── [lat | date], [lon | time], [locator | elapsed] ─────────
              // All three rows share the same color palette so the right
              // column reads as part of the card rather than secondary info.
              _wptDataRow(
                left: formatLatF(wp.lat, _coordFormat),
                right: _fmtDate(wp.timestamp, _timeUtc),
                fontSize: coordFontSize,
              ),
              _wptDataRow(
                left: formatLonF(wp.lon, _coordFormat),
                right: '${_fmtTime(wp.timestamp, _timeUtc)} ${_timeUtc ? 'UTC' : 'LCL'}',
                fontSize: coordFontSize,
              ),
              const SizedBox(height: 2),
              _wptDataRow(
                left: _locStr(wp.lat, wp.lon),
                right: formatElapsed(DateTime.now().difference(wp.timestamp)),
                fontSize: coordFontSize,
              ),
              SizedBox(height: portrait ? 6 : 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text('HOLD 3s TO DEACTIVATE',
                    style: TextStyle(
                        fontSize: 10,
                        color: _cWptHint,
                        letterSpacing: 1.5)),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  // Single row in the waypoint data section: left-aligned label, right-aligned
  // value, both the same font size and the same dim-red card colour.
  Widget _wptDataRow({
    required String left,
    required String right,
    required double fontSize,
  }) {
    final style = TextStyle(
      fontSize: fontSize,
      color: _cWptCoords,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(left, style: style),
        Text(right, style: style),
      ],
    );
  }
}

// ── City / Port detail bottom sheet ──────────────────────────────────────────
//
// Shown when the user long-presses the city section.
// Cities: population, timezone, bearing/distance.
// Ports:  all available WPI navigation fields.

class _CityDetailSheet extends StatelessWidget {
  final NearestCity nc;
  final bool dayMode;
  final Position? position;
  final SpeedUnit speedUnit;
  final CoordFormat coordFormat;
  final LocatorType locatorType;

  const _CityDetailSheet({
    required this.nc,
    required this.dayMode,
    required this.position,
    required this.speedUnit,
    required this.coordFormat,
    required this.locatorType,
  });

  bool get _isPort => nc.city.portType.isNotEmpty;

  Color get _cLabel  => dayMode ? const Color(0xFF888888) : const Color(0xFF882222);
  Color get _cValue  => dayMode ? Colors.white             : const Color(0xFFCC3333);
  // Accent: cyan in day (maritime), medium red in night (night-safe)
  Color get _cAccent => dayMode ? const Color(0xFF00E5FF)  : const Color(0xFF882222);
  // Warning: amber in day, bright red in night
  Color get _cWarn   => dayMode ? const Color(0xFFFFD740)  : const Color(0xFFCC3333);
  // Link: blue in day, medium red in night
  Color get _cLink   => dayMode ? const Color(0xFF29B6F6)  : const Color(0xFF882222);

  // ── Copy-all ──────────────────────────────────────────────────────────────

  /// Builds a plain-text representation of all displayed details so it can
  /// be pasted into a messaging app and sent to another crew member.
  String _buildCopyText() {
    final city = nc.city;
    final buf = StringBuffer();

    void line(String label, String value) {
      if (value.isEmpty || value == '0' || value == '0.0') return;
      buf.writeln('$label: $value');
    }

    // ── Header ───────────────────────────────────────────────────────────
    buf.writeln('${city.name} (${city.country})');
    if (position != null) {
      buf.writeln(
          '${nc.bearingDeg.round()}°  ${formatDistanceUnit(nc.distKm, speedUnit)}');
    }
    buf.writeln();

    // ── Reporter GPS position ─────────────────────────────────────────────
    if (position != null) {
      buf.writeln('GPS Position:');
      buf.writeln('  ${formatLatF(position!.latitude, coordFormat)}');
      buf.writeln('  ${formatLonF(position!.longitude, coordFormat)}');
      final locStr = locatorType == LocatorType.maidenhead
          ? '${maidenhead(position!.latitude, position!.longitude)} (IARU)'
          : '${mgrs(position!.latitude, position!.longitude)} (MGRS)';
      buf.writeln('  $locStr');
      buf.writeln();
    }

    // ── City fields ───────────────────────────────────────────────────────
    if (!_isPort) {
      buf.writeln('LOCATION');
      line('Country', city.country);
      if (city.population > 0) line('Population', _fmtPop(city.population));
      line('Timezone', city.timezone);
    }

    // ── Port fields ───────────────────────────────────────────────────────
    if (_isPort) {
      buf.writeln('PORT OVERVIEW');
      line('Type', city.portType);
      if (city.harbourSize.isNotEmpty) {
        line('Harbour class', switch (city.harbourSize) {
          'L'  => 'Large', 'M'  => 'Medium',
          'S'  => 'Small', 'VS' => 'Very Small',
          _    => city.harbourSize,
        });
      }
      line('Harbour type', city.harborType);
      line('Primary use', city.harborUse);
      if (city.shelter.isNotEmpty) line('Shelter', _shelter(city.shelter));
      line('NAVAREA', city.navarea);

      if (city.channelDepthM > 0 || city.tidalRangeM > 0 || city.maxVesselLengthM > 0) {
        buf.writeln();
        buf.writeln('DIMENSIONS');
        if (city.channelDepthM > 0)    line('Channel depth',    '${city.channelDepthM} m');
        if (city.tidalRangeM > 0)      line('Tidal range',      '${city.tidalRangeM} m');
        if (city.maxVesselLengthM > 0) line('Max vessel length','${city.maxVesselLengthM} m');
        line('Chart', city.chart);
      }

      if (city.pilotage.isNotEmpty || city.firstPortEntry.isNotEmpty ||
          city.entryRestrictions.isNotEmpty) {
        buf.writeln();
        buf.writeln('ENTRY REQUIREMENTS');
        if (city.firstPortEntry == 'Y') line('First port of entry', 'Yes');
        else if (city.firstPortEntry == 'N') line('First port of entry', 'No');
        line('Pilotage', city.pilotage);
        line('Entry restrictions', city.entryRestrictions);
      }

      if (city.vhf.isNotEmpty || city.phone.isNotEmpty || city.callSign.isNotEmpty) {
        buf.writeln();
        buf.writeln('COMMUNICATIONS');
        if (city.vhf.isNotEmpty) {
          line('VHF', 'Ch ${city.vhf.replaceAll(";", " / Ch ")}');
        }
        line('Call sign', city.callSign);
        line('Phone', city.phone);
      }

      if (city.publication.isNotEmpty || city.publicationLink.isNotEmpty) {
        buf.writeln();
        buf.writeln('PUBLICATIONS');
        line('Sailing directions', city.publication);
        line('Link', city.publicationLink);
      }

      if (city.facilities.isNotEmpty) {
        buf.writeln();
        buf.writeln('FACILITIES');
        buf.writeln(city.facilities
            .split('|')
            .where((f) => f.isNotEmpty)
            .map((f) => f.replaceAll('_', ' '))
            .join(', '));
      }
    }

    return buf.toString().trim();
  }

  void _copyAll(BuildContext ctx) {
    final text = _buildCopyText();
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text('Details copied — paste into any app to share',
          style: TextStyle(color: _cValue.withValues(alpha: 0.7), fontSize: 13)),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 2000),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
    child: Text(title.toUpperCase(),
        style: TextStyle(
            fontSize: 10, color: _cLabel,
            letterSpacing: 2.5, fontWeight: FontWeight.w700)),
  );

  // ── Shared snackbar ───────────────────────────────────────────────────────
  void _showCopied(BuildContext ctx, String value) {
    Clipboard.setData(ClipboardData(text: value));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(value,
          style: TextStyle(color: _cValue.withValues(alpha: 0.7), fontSize: 13),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 1200),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  // ── Generic row — long-press copies the value ──────────────────────────────
  Widget _row(BuildContext ctx, String label, String value, {Color? vc}) {
    if (value.isEmpty || value == '0' || value == '0.0') return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showCopied(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: _cLabel)),
            const SizedBox(width: 16),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 12,
                      color: vc ?? _cValue,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ],
        ),
      ),
    );
  }

  // ── Phone row — tap dials, long-press copies ───────────────────────────────
  Widget _phoneRow(BuildContext ctx, String phone) {
    if (phone.isEmpty) return const SizedBox.shrink();
    final uri = Uri.parse('tel:$phone');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
      onLongPress: () => _showCopied(ctx, phone),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Phone', style: TextStyle(fontSize: 12, color: _cLabel)),
            const SizedBox(width: 16),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.phone, size: 12, color: _cAccent),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(phone,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 12,
                            color: _cAccent,
                            decoration: TextDecoration.underline,
                            decorationColor: _cAccent,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Link row — tap opens browser, long-press copies ────────────────────────
  Widget _linkRow(BuildContext ctx, String label, String url) {
    if (url.isEmpty) return const SizedBox.shrink();
    final uri = Uri.tryParse(url);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: uri != null
          ? () => launchUrl(uri, mode: LaunchMode.externalApplication)
          : null,
      onLongPress: () => _showCopied(ctx, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: _cLabel)),
            const SizedBox(width: 16),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(url,
                        textAlign: TextAlign.right,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: _cLink,
                            decoration: TextDecoration.underline,
                            decorationColor: _cLink)),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.open_in_new, size: 12, color: _cLink),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtPop(int pop) {
    if (pop <= 0) return '';
    if (pop >= 1000000) return '${(pop / 1000000).toStringAsFixed(1)}M';
    if (pop >= 1000) return '${(pop / 1000).toStringAsFixed(0)}k';
    return '$pop';
  }

  String _shelter(String s) => switch (s) {
    'E' => 'Excellent',
    'G' => 'Good',
    'F' => 'Fair',
    'P' => 'Poor',
    _   => s,
  };

  // Shelter quality colour — graded in day (green→red), graded in night (all reds).
  // In night mode brighter red = better shelter so the relative quality reads
  // the same without using non-red colours.
  Color _shelterColor(String s) {
    if (dayMode) {
      return switch (s) {
        'E' => const Color(0xFF55DD55),
        'G' => const Color(0xFF9CCC65),
        'F' => const Color(0xFFFFD740),
        'P' => const Color(0xFFFF7043),
        _   => _cValue,
      };
    } else {
      return switch (s) {
        'E' => const Color(0xFFCC3333),
        'G' => const Color(0xFF882222),
        'F' => const Color(0xFF661111),
        'P' => const Color(0xFF551111),
        _   => _cValue,
      };
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final city = nc.city;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.92,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF111111),
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Column(children: [
          // Drag handle row with copy-all button
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2, right: 4),
            child: Row(children: [
              const SizedBox(width: 48),
              Expanded(
                child: Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: const Color(0xFF333333),
                        borderRadius: BorderRadius.circular(2))),
                ),
              ),
              SizedBox(
                width: 48,
                child: IconButton(
                  icon: Icon(Icons.content_copy, size: 20, color: _cLabel),
                  tooltip: 'Copy all details',
                  onPressed: () => _copyAll(ctx),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              controller: ctrl,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: [
                // Header — long-press copies the name
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _showCopied(ctx, city.name),
                  child: Text(city.name,
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700,
                          color: _cValue)),
                ),
                const SizedBox(height: 4),
                if (position != null) ...[
                  Text(
                    '${nc.bearingDeg.round()}°  ·  '
                    '${formatDistanceUnit(nc.distKm, speedUnit)}  ·  '
                    '${city.country}',
                    style: TextStyle(fontSize: 13, color: _cLabel)),
                ],

                // ── City fields ───────────────────────────────────────────
                if (!_isPort) ...[
                  _section('Location'),
                  _row(ctx, 'Country', city.country),
                  _row(ctx, 'Population', _fmtPop(city.population)),
                  _row(ctx, 'Timezone', city.timezone),
                ],

                // ── Port fields ───────────────────────────────────────────
                if (_isPort) ...[
                  _section('Port overview'),
                  _row(ctx, 'Type', city.portType),
                  _row(ctx, 'Harbour class', switch (city.harbourSize) {
                    'L'  => 'Large',
                    'M'  => 'Medium',
                    'S'  => 'Small',
                    'VS' => 'Very Small',
                    _    => city.harbourSize,
                  }),
                  _row(ctx, 'Harbour type', city.harborType),
                  _row(ctx, 'Primary use', city.harborUse),
                  _row(ctx, 'Shelter', _shelter(city.shelter),
                      vc: _shelterColor(city.shelter)),
                  _row(ctx, 'NAVAREA', city.navarea),

                  if (city.channelDepthM > 0 || city.tidalRangeM > 0 ||
                      city.maxVesselLengthM > 0) ...[
                    _section('Dimensions'),
                    _row(ctx, 'Channel depth',
                        city.channelDepthM > 0 ? '${city.channelDepthM} m' : ''),
                    _row(ctx, 'Tidal range',
                        city.tidalRangeM > 0 ? '${city.tidalRangeM} m' : ''),
                    _row(ctx, 'Max vessel length',
                        city.maxVesselLengthM > 0 ? '${city.maxVesselLengthM} m' : ''),
                    _row(ctx, 'Chart', city.chart),
                  ],

                  if (city.pilotage.isNotEmpty ||
                      city.firstPortEntry.isNotEmpty ||
                      city.entryRestrictions.isNotEmpty) ...[
                    _section('Entry requirements'),
                    _row(ctx, 'First port of entry',
                        city.firstPortEntry == 'Y' ? 'Yes' :
                        city.firstPortEntry == 'N' ? 'No'  : ''),
                    _row(ctx, 'Pilotage', city.pilotage),
                    _row(ctx, 'Entry restrictions', city.entryRestrictions,
                        vc: city.entryRestrictions.isNotEmpty ? _cWarn : null),
                  ],

                  if (city.vhf.isNotEmpty || city.phone.isNotEmpty ||
                      city.callSign.isNotEmpty) ...[
                    _section('Communications'),
                    _row(ctx, 'VHF working channel', city.vhf.isNotEmpty
                        ? 'Ch ${city.vhf.replaceAll(";", " / Ch ")}' : '',
                        vc: _cAccent),
                    _row(ctx, 'Call sign', city.callSign, vc: _cAccent),
                    _phoneRow(ctx, city.phone),
                  ],

                  if (city.publication.isNotEmpty ||
                      city.publicationLink.isNotEmpty) ...[
                    _section('Publications'),
                    _row(ctx, 'Sailing directions', city.publication),
                    _linkRow(ctx, 'Link', city.publicationLink),
                  ],

                  if (city.facilities.isNotEmpty) ...[
                    _section('Facilities'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: city.facilities.split('|')
                          .where((f) => f.isNotEmpty)
                          .map((f) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A1A),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: const Color(0xFF333333), width: 1)),
                            child: Text(f.replaceAll('_', ' '),
                                style: TextStyle(
                                    fontSize: 11, color: _cLabel)),
                          ))
                          .toList(),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Waypoint card border painter ──────────────────────────────────────────────
class _WptBorderPainter extends CustomPainter {
  final double progress;
  final bool dayMode;
  const _WptBorderPainter(this.progress, {required this.dayMode});

  static const _trackWidth = 1.5;
  static const _arcWidth = 5.5;
  static const _borderRadius = Radius.circular(6.0);

  @override
  void paint(Canvas canvas, Size size) {
    const inset = _arcWidth / 2 + 1.0;
    final rrect = RRect.fromLTRBR(
        inset, inset, size.width - inset, size.height - inset, _borderRadius);

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _trackWidth
        ..color = progress > 0
            ? (dayMode ? const Color(0xFF4A1515) : const Color(0xFF2A0A0A))
            : (dayMode ? const Color(0xFF3D1212) : const Color(0xFF1A0808)),
    );

    if (progress <= 0) return;

    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final arc = metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0));

    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _arcWidth
        ..color = dayMode
            ? Color.lerp(const Color(0xFFFF3333), const Color(0xFFFF6666), progress)!
            : Color.lerp(const Color(0xFF882222), const Color(0xFFAA3333), progress)!
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WptBorderPainter old) =>
      old.progress != progress || old.dayMode != dayMode;
}
