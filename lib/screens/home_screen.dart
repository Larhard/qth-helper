import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/city_service.dart';
import '../services/declination_service.dart';
import '../utils/coordinate_utils.dart';
import '../utils/geo_utils.dart';
import '../widgets/arrow_widget.dart';
import '../widgets/hold_to_clear_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // ── Constants ─────────────────────────────────────────────────────────────
  /// Speed above which GPS course replaces compass (m/s ≈ 5.4 km/h).
  static const _gpsThresholdMs = 1.5;
  /// Minimum ms between compass setState calls (~12 Hz).
  static const _compassIntervalMs = 80;
  /// Only recalculate nearest city after moving this many metres.
  static const _cityRecalcThresholdM = 100.0;

  // ── Streams ───────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // ── State ─────────────────────────────────────────────────────────────────
  Position? _position;
  /// Magnetic heading corrected for declination → true north.
  double _compassHeading = 0;
  /// GPS course; only updated when speed ≥ threshold to avoid noise.
  double? _lastValidGpsHeading;
  NearestCity? _nearestCity;
  Position? _lastCityCalcPos;
  ({double lat, double lon})? _mob;
  String? _error;
  int _lastCompassMs = 0;

  // ── Derived getters ───────────────────────────────────────────────────────
  bool get _usingGps {
    final p = _position;
    return p != null && p.speed >= _gpsThresholdMs && !p.heading.isNaN && p.heading >= 0;
  }

  double get _heading => _usingGps ? _position!.heading : _compassHeading;

  /// The other source's heading, used for the dimmed secondary arrow.
  double? get _secondaryHeading => _usingGps ? _compassHeading : _lastValidGpsHeading;

  Color get _headingColor =>
      _usingGps ? const Color(0xFF69F0AE) : Colors.white;

  String get _sourceLabel => _usingGps ? 'TRUE · GPS' : 'TRUE · MAG';

  // ── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMob();
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  /// Pause compass when backgrounded; resume on foreground. Saves battery.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _compassSub?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _compassSub?.resume();
    }
  }

  // ── MOB persistence ──────────────────────────────────────────────────────
  Future<void> _loadMob() async {
    final p = await SharedPreferences.getInstance();
    final lat = p.getDouble('mob_lat');
    final lon = p.getDouble('mob_lon');
    if (lat != null && lon != null && mounted) {
      setState(() => _mob = (lat: lat, lon: lon));
    }
  }

  Future<void> _saveMob(double lat, double lon) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('mob_lat', lat);
    await p.setDouble('mob_lon', lon);
  }

  Future<void> _deleteMob() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('mob_lat');
    await p.remove('mob_lon');
  }

  // ── Stream init ──────────────────────────────────────────────────────────
  Future<void> _init() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      if (mounted) setState(() => _error = 'Location permission required.\nEnable it in Settings.');
      return;
    }

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high, // good accuracy, less drain than "best"
        distanceFilter: 2,               // only fire when moved ≥ 2 m
      ),
    ).listen((pos) {
      // Cache valid GPS course (above threshold only) to avoid noise artifacts.
      if (pos.speed >= _gpsThresholdMs && !pos.heading.isNaN && pos.heading >= 0) {
        _lastValidGpsHeading = pos.heading;
      }

      // Throttle city recalc to every 100 m.
      final needsCityUpdate = _lastCityCalcPos == null ||
          Geolocator.distanceBetween(
                _lastCityCalcPos!.latitude,
                _lastCityCalcPos!.longitude,
                pos.latitude,
                pos.longitude,
              ) >=
              _cityRecalcThresholdM;

      if (needsCityUpdate) {
        _lastCityCalcPos = pos;
        final city = CityService.instance.nearest(pos.latitude, pos.longitude);
        if (mounted) setState(() { _position = pos; _nearestCity = city; });
      } else {
        if (mounted) setState(() => _position = pos);
      }

      // Declination update is fire-and-forget; no rebuild needed here.
      DeclinationService.instance.update(pos.latitude, pos.longitude, pos.altitude);
    });

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null) return;
      // Throttle to _compassIntervalMs to avoid excess redraws.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastCompassMs < _compassIntervalMs) return;
      _lastCompassMs = now;
      final corrected = (h + DeclinationService.instance.declination + 360) % 360;
      if (mounted) setState(() => _compassHeading = corrected);
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  void _setMob() {
    final pos = _position;
    if (pos == null) return;
    HapticFeedback.heavyImpact();
    _saveMob(pos.latitude, pos.longitude);
    setState(() => _mob = (lat: pos.latitude, lon: pos.longitude));
  }

  void _clearMob() {
    _deleteMob();
    setState(() => _mob = null);
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

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildError(_error!);
    if (_position == null) return _buildWaiting();
    return _buildMain();
  }

  Widget _buildWaiting() => const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(color: Colors.white24),
            SizedBox(height: 20),
            Text('Acquiring GPS…',
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _headingSection(pos),
              _divider(),
              _coordsSection(pos),
              _divider(),
              if (_nearestCity != null) _citySection(_nearestCity!),
              const Spacer(),
              _mobSection(pos),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Divider(color: Color(0xFF1A1A1A), height: 1),
      );

  // ── Heading ──────────────────────────────────────────────────────────────
  Widget _headingSection(Position pos) {
    final color = _headingColor;
    final primary = _heading;
    final secondary = _secondaryHeading;
    final speedKmh = pos.speed * 3.6;
    final speedStr = speedKmh < 0.5
        ? '0.0 km/h'
        : speedKmh < 10
            ? '${speedKmh.toStringAsFixed(1)} km/h'
            : '${speedKmh.round()} km/h';

    return Row(children: [
      SizedBox(
        width: 80,
        height: 80,
        child: Stack(alignment: Alignment.center, children: [
          // Secondary arrow — dimmed, only when we have a value for it.
          if (secondary != null)
            Opacity(
              opacity: 0.18,
              child: ArrowWidget(bearingDeg: secondary, color: Colors.white, size: 80),
            ),
          // Primary arrow — full color.
          ArrowWidget(bearingDeg: primary, color: color, size: 80),
        ]),
      ),
      const SizedBox(width: 20),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '${primary.round()}°',
          style: TextStyle(
            fontSize: 64,
            fontWeight: FontWeight.w900,
            color: color,
            height: 1.0,
          ),
        ),
        Text(
          speedStr,
          style: const TextStyle(
            fontSize: 17,
            color: Color(0xFF555555),
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          _sourceLabel,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF3A3A3A),
            letterSpacing: 2.5,
          ),
        ),
      ]),
    ]);
  }

  // ── Coordinates ──────────────────────────────────────────────────────────
  Widget _coordsSection(Position pos) {
    final latStr = formatLat(pos.latitude);
    final lonStr = formatLon(pos.longitude);
    final locStr = maidenhead(pos.latitude, pos.longitude);

    const coordStyle = TextStyle(
      fontSize: 30,
      color: Color(0xFF00E5FF),
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Tap the coordinate block to copy both lines.
      GestureDetector(
        onTap: () => _copyToClipboard('$latStr\n$lonStr'),
        behavior: HitTestBehavior.opaque,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(latStr, style: coordStyle),
          const SizedBox(height: 2),
          Text(lonStr, style: coordStyle),
        ]),
      ),
      const SizedBox(height: 10),
      // Tap the locator to copy just the locator string.
      GestureDetector(
        onTap: () => _copyToClipboard(locStr),
        child: Text(
          locStr,
          style: const TextStyle(
            fontSize: 28,
            color: Color(0xFF69F0AE),
            fontWeight: FontWeight.w700,
            letterSpacing: 4,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ]);
  }

  // ── City ─────────────────────────────────────────────────────────────────
  Widget _citySection(NearestCity nc) {
    return Row(children: [
      ArrowWidget(bearingDeg: nc.bearingDeg, color: const Color(0xFFFFD740), size: 60),
      const SizedBox(width: 16),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nc.city.name,
            style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFFD740))),
        Row(children: [
          Text('${nc.bearingDeg.round()}°',
              style: const TextStyle(
                  fontSize: 20,
                  color: Color(0xFFFFAB40),
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 18),
          Text(formatDistance(nc.distKm),
              style: const TextStyle(
                  fontSize: 20,
                  color: Color(0xFFFFD740),
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ]),
    ]);
  }

  // ── MOB ──────────────────────────────────────────────────────────────────
  Widget _mobSection(Position pos) {
    if (_mob == null) {
      return SizedBox(
        width: double.infinity,
        height: 80,
        child: ElevatedButton(
          onPressed: _setMob,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB71C1C),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            elevation: 0,
          ),
          child: const Text('MOB',
              style: TextStyle(
                  fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 5)),
        ),
      );
    }

    final mob = _mob!;
    final b = bearing(pos.latitude, pos.longitude, mob.lat, mob.lon);
    final d = haversineKm(pos.latitude, pos.longitude, mob.lat, mob.lon);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD32F2F), width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // Arrow pointing to MOB
        ArrowWidget(bearingDeg: b, color: const Color(0xFFFF5252), size: 60),
        const SizedBox(width: 14),
        // Info block
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('MOB',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFFFF5252),
                    letterSpacing: 3)),
            Row(children: [
              Text('${b.round()}°',
                  style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFFFF1744),
                      fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(width: 14),
              Text(formatDistance(d),
                  style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFFFF5252),
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 4),
            // MOB point coordinates
            Text(formatLat(mob.lat),
                style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF883333),
                    fontFeatures: [FontFeature.tabularFigures()])),
            Text(formatLon(mob.lon),
                style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF883333),
                    fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        ),
        // Hold-to-clear button
        HoldToClearButton(onConfirmed: _clearMob),
      ]),
    );
  }
}
