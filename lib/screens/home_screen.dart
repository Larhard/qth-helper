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
  Color get _headingColor => _usingGps ? const Color(0xFF69F0AE) : Colors.white;
  String get _sourceLabel => _usingGps ? 'GPS' : 'MAG';

  // Color progression: orange → amber → sky-blue (clearly distinct from
  // the green GPS arrow and cyan coordinate display).
  Color get _cityColor => switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFFF9800),
    CityMode.precise  => const Color(0xFFFFD740),
    CityMode.detailed => const Color(0xFF4FC3F7),
  };
  Color get _citySubColor => switch (CityService.instance.mode) {
    CityMode.large    => const Color(0xFFE65100),
    CityMode.precise  => const Color(0xFFFFAB40),
    CityMode.detailed => const Color(0xFF0091EA),
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
      _compassSub?.pause();
      _cancelClear();
    } else if (state == AppLifecycleState.resumed) {
      _compassSub?.resume();
    }
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
      _cachedLatStr = formatLat(pos.latitude);
      _cachedLonStr = formatLon(pos.longitude);
      _cachedLocStr = maidenhead(pos.latitude, pos.longitude);
      _cachedAlt = pos.altitude;
      _cachedAccuracy = pos.accuracy;

      // ── GPS heading ───────────────────────────────────────────────────────
      if (pos.speed >= _gpsThresholdMs &&
          !pos.heading.isNaN &&
          pos.heading >= 0) {
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

  // ── Track azimuth ─────────────────────────────────────────────────────────
  void _updateTrackBearing(Position pos) {
    if (pos.speed < 0.5) return; // no meaningful direction when nearly stationary

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
                iconSize: 20,
                color: const Color(0xFF3A3A3A),
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

  Widget _buildLandscape(Position pos) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 140, child: _headingSectionLandscape(pos)),
          const SizedBox(width: 32),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _coordsSectionLandscape(),
                if (_nearestCity != null) ...[
                  _dividerCompact(),
                  _citySectionLandscape(_nearestCity!),
                ],
                _dividerCompact(),
                _wptSectionLandscape(pos),
              ],
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
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Color(0xFF909090),
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        Text(_sourceLabel,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF686868), letterSpacing: 2.5)),
        if (_trackBearing != null && _gpsStaleSeconds < 30)
          Text('TRK ${_trackBearing!.round()}°',
              style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF4A4A4A),
                  letterSpacing: 1.5)),
      ]),
    ]);
  }

  Widget _headingSectionLandscape(Position pos) {
    final color = _headingColor;
    final primary = _heading;
    return Column(
      mainAxisSize: MainAxisSize.min,
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
        const SizedBox(height: 4),
        Text('${primary.round()}°',
            style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w900,
                color: color,
                height: 1.0)),
        const SizedBox(height: 2),
        GestureDetector(
          onLongPress: _cycleSpeedUnit,
          child: Text(
            formatSpeed(pos.speed, _speedUnit),
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF909090),
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        Text(_sourceLabel,
            style: const TextStyle(
                fontSize: 11, color: Color(0xFF686868), letterSpacing: 2.0)),
        if (_trackBearing != null && _gpsStaleSeconds < 30)
          Text('TRK ${_trackBearing!.round()}°',
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF4A4A4A),
                  letterSpacing: 1.5)),
      ],
    );
  }

  // ── Coordinates ───────────────────────────────────────────────────────────
  Widget _coordsSection() {
    final stale = _gpsStaleSeconds > 10;
    final coordColor =
        stale ? const Color(0xFF006080) : const Color(0xFF00E5FF);
    final locColor =
        stale ? const Color(0xFF2A6040) : const Color(0xFF69F0AE);

    const coordStyle = TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => _copyToClipboard('$_cachedLatStr\n$_cachedLonStr'),
        behavior: HitTestBehavior.opaque,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_cachedLatStr,
              style: coordStyle.copyWith(color: coordColor)),
          const SizedBox(height: 2),
          Text(_cachedLonStr,
              style: coordStyle.copyWith(color: coordColor)),
        ]),
      ),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () => _copyToClipboard(_cachedLocStr),
        child: Text(_cachedLocStr,
            style: TextStyle(
                fontSize: 28,
                color: locColor,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      const SizedBox(height: 6),
      _altAccuracyRow(stale),
    ]);
  }

  Widget _coordsSectionLandscape() {
    final stale = _gpsStaleSeconds > 10;
    final coordColor =
        stale ? const Color(0xFF006080) : const Color(0xFF00E5FF);
    final locColor =
        stale ? const Color(0xFF2A6040) : const Color(0xFF69F0AE);

    const coordStyle = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => _copyToClipboard('$_cachedLatStr\n$_cachedLonStr'),
        behavior: HitTestBehavior.opaque,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_cachedLatStr, style: coordStyle.copyWith(color: coordColor)),
          const SizedBox(height: 2),
          Text(_cachedLonStr, style: coordStyle.copyWith(color: coordColor)),
        ]),
      ),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: () => _copyToClipboard(_cachedLocStr),
        child: Text(_cachedLocStr,
            style: TextStyle(
                fontSize: 20,
                color: locColor,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      const SizedBox(height: 4),
      _altAccuracyRow(stale),
    ]);
  }

  Widget _altAccuracyRow(bool stale) {
    final altStr = formatAlt(_cachedAlt, _speedUnit);
    final accStr = '±${_cachedAccuracy.round()} m';
    final staleStr = stale ? '  GPS ${_gpsStaleSeconds}s' : '';
    return Row(children: [
      Text('alt $altStr',
          style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF555555),
              fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(width: 12),
      Text('$accStr$staleStr',
          style: TextStyle(
              fontSize: 12,
              color: stale ? const Color(0xFFB05000) : const Color(0xFF444444),
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
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
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(nc.city.name,
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w700, color: color)),
          Row(children: [
            Text('${nc.bearingDeg.round()}°',
                style: TextStyle(
                    fontSize: 20,
                    color: subColor,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 18),
            Text(formatDistanceUnit(nc.distKm, _speedUnit),
                style: TextStyle(
                    fontSize: 20,
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
        ArrowWidget(bearingDeg: nc.bearingDeg, color: color, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(nc.city.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700, color: color)),
              ),
              const SizedBox(width: 8),
              Text(nc.city.country,
                  style: TextStyle(
                      fontSize: 13,
                      color: subColor.withValues(alpha: 0.7))),
            ]),
            Row(children: [
              Text('${nc.bearingDeg.round()}°',
                  style: TextStyle(
                      fontSize: 16,
                      color: subColor,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 14),
              Text(formatDistanceUnit(nc.distKm, _speedUnit),
                  style: TextStyle(
                      fontSize: 16,
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
        height: 56,
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
                  fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 4)),
        ),
      );
    }
    return _wptCard(pos, wp, portrait: false);
  }

  Widget _wptCard(Position pos, Waypoint wp, {required bool portrait}) {
    final b = bearing(pos.latitude, pos.longitude, wp.lat, wp.lon);
    final d = haversineKm(pos.latitude, pos.longitude, wp.lat, wp.lon);
    final arrowSize = portrait ? 60.0 : 44.0;
    final nameFontSize = portrait ? 18.0 : 16.0;
    final dataFontSize = portrait ? 20.0 : 16.0;
    final coordFontSize = portrait ? 14.0 : 12.0;
    final padding = portrait
        ? const EdgeInsets.fromLTRB(14, 12, 14, 14)
        : const EdgeInsets.fromLTRB(12, 8, 12, 8);

    return Listener(
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
                    color: const Color(0xFFFF5252),
                    size: arrowSize),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(wp.name,
                      style: TextStyle(
                          fontSize: nameFontSize,
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFFFF5252),
                          letterSpacing: 1.5)),
                  Row(children: [
                    Text('${b.round()}°',
                        style: TextStyle(
                            fontSize: dataFontSize,
                            color: const Color(0xFFFF1744),
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const SizedBox(width: 14),
                    Text(formatDistanceUnit(d, _speedUnit),
                        style: TextStyle(
                            fontSize: dataFontSize,
                            color: const Color(0xFFFF5252),
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ]),
                ]),
              ]),
              SizedBox(height: portrait ? 6 : 4),
              Text(formatLat(wp.lat),
                  style: TextStyle(
                      fontSize: coordFontSize,
                      color: const Color(0xFF883333),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              Text(formatLon(wp.lon),
                  style: TextStyle(
                      fontSize: coordFontSize,
                      color: const Color(0xFF883333),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              SizedBox(height: portrait ? 8 : 4),
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
