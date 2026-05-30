import 'dart:async';
import 'dart:math' show cos, sqrt;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
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
import 'waypoints_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ── Constants ─────────────────────────────────────────────────────────────
  static const _gpsThresholdMs = 1.5;    // m/s ≈ 5.4 km/h
  static const _compassIntervalMs = 100; // ~10 Hz — slightly lower than before
  static const _cityRecalcThresholdM = 100.0;
  static const _trackBufferSize = 8;
  static const _trackMinDistM = 20.0;    // min distance between track samples

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
  // Smoothed direction of travel: bearing from oldest to newest in a ring
  // buffer of evenly-spaced GPS positions. Much less noisy than last-2-point
  // bearing, especially at low speed or with antenna jitter.
  final _trackBuffer = <({double lat, double lon})>[];
  double? _trackBearing;

  // ── GPS staleness ─────────────────────────────────────────────────────────
  Timer? _staleTimer;
  DateTime _lastGpsFix = DateTime.now();
  int _gpsStaleSeconds = 0; // 0 = fresh; > 0 = seconds since last fix

  // ── Speed unit ────────────────────────────────────────────────────────────
  SpeedUnit _speedUnit = loadSpeedUnit();

  // ── Time display ──────────────────────────────────────────────────────────
  bool _timeUtc = loadTimeUtc();
  String _cachedDateStr = '';
  String _cachedTimeStr = '';

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

  // ── Derived ───────────────────────────────────────────────────────────────
  bool get _usingGps {
    final p = _position;
    return p != null && p.speed >= _gpsThresholdMs && !p.heading.isNaN && p.heading >= 0;
  }

  double get _heading => _usingGps ? _position!.heading : _compassHeading;
  Color get _headingColor => _usingGps ? const Color(0xFF55DD55) : Colors.white;
  String get _sourceLabel => _usingGps ? 'GPS' : 'MAG';

  // Color progression follows the warm spectrum — orange → amber → lime —
  // so all three levels read as "the same concept at increasing resolution."
  // The traffic-light metaphor (orange/yellow/green) reinforces the scale
  // intuitively without requiring the user to memorise anything.
  // Lime (#C6FF00) is clearly distinct from the mint green of the GPS arrow
  // and IARU locator (#69F0AE), avoiding cross-section confusion.
  Color get _cityColor => switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFFF9800),  // orange   — global overview
    CityMode.precise  => const Color(0xFFFFD740),  // amber    — regional
    CityMode.detailed => const Color(0xFFC6FF00),  // lime     — local detail
  };
  Color get _citySubColor => switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFE65100),  // deep orange
    CityMode.precise  => const Color(0xFFFFAB40),  // light amber
    CityMode.detailed => const Color(0xFFAEEA00),  // darker lime
  };

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holdTicker = createTicker(_onHoldTick);
    _staleTimer = Timer.periodic(const Duration(seconds: 1), _onStaleTick);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTicker.dispose();
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
      // Screen off → release every continuously-running power draw:
      //  • compass sensor (paused)
      //  • GNSS receiver (stream cancelled — the big saving on long hikes)
      //  • 1 Hz stale timer (cancelled — no point waking the CPU for hidden UI)
      _compassSub?.pause();
      _posSub?.cancel();
      _posSub = null;
      _staleTimer?.cancel();
      _staleTimer = null;
      _cancelClear();
    } else if (state == AppLifecycleState.resumed) {
      _compassSub?.resume();
      // Restart everything that was torn down on pause.
      _staleTimer ??= Timer.periodic(const Duration(seconds: 1), _onStaleTick);
      if (_posSub == null) _startPositionStream();
      // Request one immediate fix so the stale indicator clears within seconds
      // rather than waiting for the freshly-restarted stream's first event.
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
      _cachedDateStr = _fmtDate(pos.timestamp, _timeUtc);
      _cachedTimeStr = _fmtTime(pos.timestamp, _timeUtc);
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
    // Only call setState when crossing the threshold or already stale
    if ((sec > 10) != (_gpsStaleSeconds > 10)) {
      setState(() => _gpsStaleSeconds = sec);
    } else if (_gpsStaleSeconds > 10) {
      setState(() => _gpsStaleSeconds = sec);
    }
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
      if (!_usingGps && mounted) setState(() {});
    });
  }

  // The position stream is cancelled when the screen turns off (see lifecycle
  // handler) and recreated here on resume, so the GNSS receiver isn't draining
  // power during long screen-off stretches on a hike.
  void _startPositionStream() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      // ── Freshness ─────────────────────────────────────────────────────────
      _lastGpsFix = DateTime.now();
      if (_gpsStaleSeconds > 0) _gpsStaleSeconds = 0;

      // ── Cache display strings (avoid recomputing in build) ────────────────
      _cachedLatStr = formatLatF(pos.latitude, _coordFormat);
      _cachedLonStr = formatLonF(pos.longitude, _coordFormat);
      _cachedLocStr = _locStr(pos.latitude, pos.longitude);
      _cachedAlt = pos.altitude;
      _cachedAccuracy = pos.accuracy;
      _cachedDateStr = _fmtDate(pos.timestamp, _timeUtc);
      _cachedTimeStr = _fmtTime(pos.timestamp, _timeUtc);

      // ── GPS heading ───────────────────────────────────────────────────────
      // Primary source switches at _gpsThresholdMs (1.5 m/s). The last-known
      // GPS heading is cached at a lower threshold so the secondary arrow
      // appears even at walking pace — GPS course is usable above ~0.5 m/s.
      if (pos.speed >= 0.5 && !pos.heading.isNaN && pos.heading >= 0) {
        _lastValidGpsHeading = pos.heading;
      }

      // ── Track azimuth ─────────────────────────────────────────────────────
      _updateTrackBearing(pos);

      // ── Declination (throttled inside the service) ────────────────────────
      DeclinationService.instance
          .update(pos.latitude, pos.longitude, pos.altitude);

      // ── City recalc ───────────────────────────────────────────────────────
      final needsCity = _lastCityCalcPos == null ||
          Geolocator.distanceBetween(
                _lastCityCalcPos!.latitude, _lastCityCalcPos!.longitude,
                pos.latitude, pos.longitude,
              ) >=
              _cityRecalcThresholdM;

      if (needsCity) {
        _lastCityCalcPos = pos;
        final city =
            CityService.instance.nearest(pos.latitude, pos.longitude);
        if (mounted) setState(() { _position = pos; _nearestCity = city; });
      } else {
        if (mounted) setState(() => _position = pos);
      }
    });
  }

  // ── Track azimuth ─────────────────────────────────────────────────────────
  void _updateTrackBearing(Position pos) {
    // Distance filter below handles noise — no speed gate here.
    // Slow hiking (< 3.6 km/h) still produces a meaningful course bearing.

    if (_trackBuffer.isNotEmpty) {
      final last = _trackBuffer.last;
      // Fast flat-earth distance check
      final dLat = (pos.latitude - last.lat) * 111320;
      final dLon = (pos.longitude - last.lon) *
          111320 *
          cos(last.lat * 3.14159265 / 180);
      if (sqrt(dLat * dLat + dLon * dLon) < _trackMinDistM) return;
    }

    if (_trackBuffer.length >= _trackBufferSize) _trackBuffer.removeAt(0);
    _trackBuffer.add((lat: pos.latitude, lon: pos.longitude));

    if (_trackBuffer.length >= 2) {
      final first = _trackBuffer.first;
      _trackBearing =
          bearing(first.lat, first.lon, pos.latitude, pos.longitude);
    }
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
    setState(() {
      _timeUtc = !_timeUtc;
      final pos = _position;
      if (pos != null) {
        _cachedDateStr = _fmtDate(pos.timestamp, _timeUtc);
        _cachedTimeStr = _fmtTime(pos.timestamp, _timeUtc);
      }
    });
    saveTimeUtc(_timeUtc);
    HapticFeedback.lightImpact();
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
            // Waypoints list — small, deliberate tap required.
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.pin_drop_outlined),
                iconSize: 22,
                color: const Color(0xFF888888),
                onPressed: _openWaypoints,
                tooltip: 'Waypoints',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
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
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFF1A1A1A), width: 1),
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

  Widget _divider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Divider(color: Color(0xFF1A1A1A), height: 1),
      );

  Widget _dividerCompact() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(color: Color(0xFF1A1A1A), height: 1),
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
                  _usingGps ? compassBearing : _lastValidGpsHeading;
              if (secondaryBearing == null) return const SizedBox.shrink();
              return Opacity(
                opacity: 0.38,
                child: ArrowWidget(
                    bearingDeg: secondaryBearing,
                    color: Colors.white,
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
            style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: Color(0xFFD8D8D8),
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        Text(_sourceLabel,
            style: const TextStyle(
                fontSize: 13, color: Color(0xFFBBBBBB), letterSpacing: 2.5)),
        Text(
          _trackBearing != null ? 'TRK ${_trackBearing!.round()}°' : 'TRK ---',
          style: const TextStyle(
              fontSize: 13,
              color: Color(0xFFB0B0B0),
              letterSpacing: 1.5),
        ),
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
                    _usingGps ? compassBearing : _lastValidGpsHeading;
                if (secondaryBearing == null) return const SizedBox.shrink();
                return Opacity(
                  opacity: 0.38,
                  child: ArrowWidget(
                      bearingDeg: secondaryBearing,
                      color: Colors.white,
                      size: 80),
                );
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
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFD8D8D8),
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            Text(_sourceLabel,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFBBBBBB), letterSpacing: 2.0)),
            Text(
              _trackBearing != null ? 'TRK ${_trackBearing!.round()}°' : 'TRK ---',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFFB0B0B0), letterSpacing: 1.5),
            ),
          ],
        ),
      ],
    );
  }

  // ── Coordinates ───────────────────────────────────────────────────────────
  Widget _coordsSection() {
    // Coordinates are "medium" priority — smaller than the locator (critical)
    // but bigger than altitude (tertiary). Long-press cycles the format.
    const coordStyle = TextStyle(
      fontSize: 22,
      color: Color(0xFFFFFFFF),
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
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
    const coordStyle = TextStyle(
      fontSize: 22,
      color: Color(0xFFFFFFFF),
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
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
    final locColor =
        isMaidenhead ? const Color(0xFF55DD55) : const Color(0xFFFFA726);
    final labelColor =
        isMaidenhead ? const Color(0xFF3DBF3D) : const Color(0xFFE65100);
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
          style: const TextStyle(
              fontSize: 13,
              color: Color(0xFFAAAAAA),
              fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(width: 12),
      Text('$accStr$staleStr',
          style: TextStyle(
              fontSize: 13,
              color: stale ? const Color(0xFFFF7043) : const Color(0xFF999999),
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }

  Widget _timeRow({double fontSize = 18.0}) {
    if (_cachedTimeStr.isEmpty) return const SizedBox.shrink();
    // UTC = green (universal standard — matches IARU locator convention).
    // LCL = amber (regional/local — matches MGRS locator convention).
    final color = _timeUtc ? const Color(0xFF55DD55) : const Color(0xFFFFB74D);
    final label = _timeUtc ? 'UTC' : 'LCL';
    final labelColor =
        _timeUtc ? const Color(0xFF3DBF3D) : const Color(0xFFE65100);
    final labelSize = fontSize >= 16 ? 12.0 : 11.0;
    return GestureDetector(
      onLongPress: _toggleTimeZone,
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        Text(_cachedDateStr,
            style: TextStyle(
                fontSize: fontSize,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Text(_cachedTimeStr,
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
  Widget _citySection(NearestCity nc) {
    final color = _cityColor;
    final subColor = _citySubColor;
    return GestureDetector(
      onTap: _toggleCityMode,
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        ArrowWidget(bearingDeg: nc.bearingDeg, color: color, size: 60),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(nc.city.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 32, fontWeight: FontWeight.w700, color: color)),
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
      behavior: HitTestBehavior.opaque,
      child: Row(children: [
        ArrowWidget(bearingDeg: nc.bearingDeg, color: color, size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(nc.city.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w700, color: color)),
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
            backgroundColor: const Color(0xFFB71C1C),
            foregroundColor: Colors.white,
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
            backgroundColor: const Color(0xFFB71C1C),
            foregroundColor: Colors.white,
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
        painter: _WptBorderPainter(_clearProgress),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                ArrowWidget(
                    bearingDeg: b,
                    color: const Color(0xFFFF3333),
                    size: arrowSize),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(wp.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: nameFontSize,
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFFFF3333),
                          letterSpacing: 1.5)),
                  Row(children: [
                    Text('${b.round()}°',
                        style: TextStyle(
                            fontSize: dataFontSize,
                            color: const Color(0xFFFF2020),
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const SizedBox(width: 14),
                    Text(formatDistanceUnit(d, _speedUnit),
                        style: TextStyle(
                            fontSize: dataFontSize,
                            color: const Color(0xFFFF3333),
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ]),
                ]),
              ]),
              SizedBox(height: portrait ? 6 : 4),
              Text(formatLatF(wp.lat, _coordFormat),
                  style: TextStyle(
                      fontSize: coordFontSize,
                      color: const Color(0xFFCC2222),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              Text(formatLonF(wp.lon, _coordFormat),
                  style: TextStyle(
                      fontSize: coordFontSize,
                      color: const Color(0xFFCC2222),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(
                _locStr(wp.lat, wp.lon),
                style: TextStyle(
                    fontSize: portrait ? 13.0 : 13.0,
                    color: const Color(0xFFCC2222),
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              SizedBox(height: portrait ? 6 : 4),
              const Align(
                alignment: Alignment.centerRight,
                child: Text('HOLD 3s TO DEACTIVATE',
                    style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF4A1A1A),
                        letterSpacing: 1.5)),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

// ── Waypoint card border painter ──────────────────────────────────────────────
class _WptBorderPainter extends CustomPainter {
  final double progress;
  const _WptBorderPainter(this.progress);

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
            ? const Color(0xFF4A1515)
            : const Color(0xFF3D1212),
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
        ..color =
            Color.lerp(const Color(0xFFFF3333), const Color(0xFFFF6666), progress)!
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WptBorderPainter old) => old.progress != progress;
}
