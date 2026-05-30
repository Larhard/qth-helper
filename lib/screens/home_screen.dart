import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:get_storage/get_storage.dart';
import '../services/city_service.dart';
import '../services/declination_service.dart';
import '../utils/coordinate_utils.dart';
import '../utils/geo_utils.dart';
import '../widgets/arrow_widget.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ── Constants ─────────────────────────────────────────────────────────────
  static const _gpsThresholdMs = 1.5;   // m/s ≈ 5.4 km/h
  static const _compassIntervalMs = 80; // ~12 Hz max compass redraws
  static const _cityRecalcThresholdM = 100.0;

  // ── GPS / compass streams ─────────────────────────────────────────────────
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // ── App state ─────────────────────────────────────────────────────────────
  Position? _position;
  double _compassHeading = 0;
  // ValueNotifier drives the secondary arrow directly, bypassing setState batching.
  final _compassNotifier = ValueNotifier<double>(0.0);
  double? _lastValidGpsHeading;
  NearestCity? _nearestCity;
  Position? _lastCityCalcPos;
  ({double lat, double lon})? _mob;
  String? _error;
  int _lastCompassMs = 0;

  // ── MOB hold-to-clear ───────────────────────────────────────────────────────
  // Driven by a real Stopwatch, NOT an AnimationController. The clear is gated
  // on ≥ _holdToClearMs of CONTINUOUS wall-clock holding, so it is immune to
  // ticker mute/unmute jumps (immersive UI, overlays, route changes) that could
  // otherwise make an AnimationController snap to "completed" on a brief tap.
  static const _holdToClearMs = 3000;     // required continuous hold
  static const _rewindPerFrame = 0.05;    // how fast the ring rewinds on release
  late final Ticker _holdTicker;
  final Stopwatch _holdWatch = Stopwatch();
  bool _holding = false;
  double _clearProgress = 0.0;            // 0.0 → 1.0, drives the border ring

  // ── Derived ───────────────────────────────────────────────────────────────
  bool get _usingGps {
    final p = _position;
    return p != null && p.speed >= _gpsThresholdMs && !p.heading.isNaN && p.heading >= 0;
  }

  double get _heading => _usingGps ? _position!.heading : _compassHeading;
Color get _headingColor => _usingGps ? const Color(0xFF69F0AE) : Colors.white;
  String get _sourceLabel => _usingGps ? 'TRUE · GPS' : 'TRUE · MAG';

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _holdTicker = createTicker(_onHoldTick);

    _loadMob();
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTicker.dispose();
    _compassNotifier.dispose();
    _posSub?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _compassSub?.pause();
      // If user backgrounds the app mid-hold, cancel the clear animation.
      _cancelMobClear();
    } else if (state == AppLifecycleState.resumed) {
      _compassSub?.resume();
    }
  }

  // ── MOB persistence ───────────────────────────────────────────────────────
  // GetStorage is synchronous and pure-Dart — no Android plugin, no KGP.
  static final _store = GetStorage();

  void _loadMob() {
    final lat = _store.read<double>('mob_lat');
    final lon = _store.read<double>('mob_lon');
    if (lat != null && lon != null && mounted) {
      setState(() => _mob = (lat: lat, lon: lon));
    }
  }

  void _saveMob(double lat, double lon) {
    _store.write('mob_lat', lat);
    _store.write('mob_lon', lon);
  }

  void _deleteMob() {
    _store.remove('mob_lat');
    _store.remove('mob_lon');
  }

  // ── Stream init ───────────────────────────────────────────────────────────
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
        accuracy: LocationAccuracy.high,
        distanceFilter: 2, // fire only on ≥ 2 m movement
      ),
    ).listen((pos) {
      if (pos.speed >= _gpsThresholdMs && !pos.heading.isNaN && pos.heading >= 0) {
        _lastValidGpsHeading = pos.heading;
      }

      final needsCityUpdate = _lastCityCalcPos == null ||
          Geolocator.distanceBetween(
                _lastCityCalcPos!.latitude, _lastCityCalcPos!.longitude,
                pos.latitude, pos.longitude,
              ) >= _cityRecalcThresholdM;

      if (needsCityUpdate) {
        _lastCityCalcPos = pos;
        final city = CityService.instance.nearest(pos.latitude, pos.longitude);
        if (mounted) setState(() { _position = pos; _nearestCity = city; });
      } else {
        if (mounted) setState(() => _position = pos);
      }

      DeclinationService.instance.update(pos.latitude, pos.longitude, pos.altitude);
    });

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastCompassMs < _compassIntervalMs) return;
      _lastCompassMs = now;
      final corrected = (h + DeclinationService.instance.declination + 360) % 360;
      // Always push to the notifier so the secondary arrow repaints immediately,
      // independently of whether the GPS stream is also triggering setStates.
      _compassHeading = corrected;
      _compassNotifier.value = corrected;
      // Only call setState when compass is the primary display source — the
      // primary arrow reads _compassHeading and needs a full widget rebuild.
      if (!_usingGps && mounted) setState(() {});
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
    if (mounted) setState(() => _mob = null);
  }

  /// Finger pressed down on the MOB card — begin (or resume) timing the hold.
  void _startMobClear() {
    if (_mob == null) return;
    _holding = true;
    _holdWatch
      ..reset()
      ..start();
    if (!_holdTicker.isActive) _holdTicker.start();
  }

  /// Finger lifted or gesture cancelled — stop timing. The ring then rewinds
  /// to zero. Because the stopwatch is stopped here, a brief tap can never
  /// accumulate the 3 s required to clear.
  void _cancelMobClear() {
    _holding = false;
    _holdWatch
      ..stop()
      ..reset();
    // Leave the ticker running so it can animate the ring back to 0.
    if (_clearProgress > 0 && !_holdTicker.isActive) _holdTicker.start();
  }

  /// Single source of truth for the ring + the clear decision, driven by the
  /// real stopwatch — not by any animation's internal clock.
  void _onHoldTick(Duration _) {
    if (_holding) {
      final elapsed = _holdWatch.elapsedMilliseconds;
      final p = (elapsed / _holdToClearMs).clamp(0.0, 1.0);
      if (p != _clearProgress) setState(() => _clearProgress = p);
      // Clear ONLY after a genuine, continuous 3 s hold.
      if (elapsed >= _holdToClearMs) _finishClear();
    } else {
      // Released: rewind the ring smoothly toward 0, then stop the ticker.
      final next = (_clearProgress - _rewindPerFrame).clamp(0.0, 1.0);
      setState(() => _clearProgress = next);
      if (next <= 0.0) _holdTicker.stop();
    }
  }

  void _finishClear() {
    _holding = false;
    _holdWatch
      ..stop()
      ..reset();
    _holdTicker.stop();
    setState(() => _clearProgress = 0.0);
    HapticFeedback.heavyImpact();
    _clearMob();
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text,
          style: const TextStyle(color: Colors.white60, fontSize: 13), maxLines: 2),
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
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: isLandscape ? _buildLandscape(pos) : _buildPortrait(pos),
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
          _coordsSection(pos),
          _divider(),
          if (_nearestCity != null) _citySection(_nearestCity!),
          const Spacer(),
          _mobSection(pos),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildLandscape(Position pos) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // IntrinsicHeight lets the vertical divider stretch to match the taller column.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left column: heading arrow + degrees + speed + source, stacked vertically
            // so it fits the reduced landscape height without wrapping.
            SizedBox(
              width: 140,
              child: _headingSectionLandscape(pos),
            ),
            const SizedBox(width: 20),
            Container(width: 1, color: const Color(0xFF1A1A1A)),
            const SizedBox(width: 20),
            // Right column: coordinates, city, MOB — scrollable in case of overflow.
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _coordsSection(pos),
                    if (_nearestCity != null) ...[
                      _divider(),
                      _citySection(_nearestCity!),
                    ],
                    _divider(),
                    _mobSection(pos),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Compact vertical variant of the heading section for landscape mode.
  Widget _headingSectionLandscape(Position pos) {
    final color = _headingColor;
    final primary = _heading;
    final speedKmh = pos.speed * 3.6;
    final speedStr = speedKmh < 0.5
        ? '0.0 km/h'
        : speedKmh < 10
            ? '${speedKmh.toStringAsFixed(1)} km/h'
            : '${speedKmh.round()} km/h';

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
        Text(speedStr,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF909090),
                fontFeatures: [FontFeature.tabularFigures()])),
        Text(_sourceLabel,
            style: const TextStyle(
                fontSize: 11, color: Color(0xFF686868), letterSpacing: 2.0)),
      ],
    );
  }

  Widget _divider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Divider(color: Color(0xFF1A1A1A), height: 1),
      );

  // ── Heading ───────────────────────────────────────────────────────────────
  Widget _headingSection(Position pos) {
    final color = _headingColor;
    final primary = _heading;
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
          // Secondary arrow — uses ValueListenableBuilder so it repaints on
          // every compass event directly, without waiting for a GPS setState.
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
          // Primary arrow
          ArrowWidget(bearingDeg: primary, color: color, size: 80),
        ]),
      ),
      const SizedBox(width: 20),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${primary.round()}°',
            style: TextStyle(
                fontSize: 64, fontWeight: FontWeight.w900, color: color, height: 1.0)),
        Text(speedStr,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Color(0xFF909090),
                fontFeatures: [FontFeature.tabularFigures()])),
        Text(_sourceLabel,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF686868), letterSpacing: 2.5)),
      ]),
    ]);
  }

  // ── Coordinates ───────────────────────────────────────────────────────────
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
      GestureDetector(
        onTap: () => _copyToClipboard(locStr),
        child: Text(locStr,
            style: const TextStyle(
                fontSize: 28,
                color: Color(0xFF69F0AE),
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
                fontFeatures: [FontFeature.tabularFigures()])),
      ),
    ]);
  }

  // ── City ──────────────────────────────────────────────────────────────────
  Widget _citySection(NearestCity nc) {
    return Row(children: [
      ArrowWidget(bearingDeg: nc.bearingDeg, color: const Color(0xFFFFD740), size: 60),
      const SizedBox(width: 16),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nc.city.name,
            style: const TextStyle(
                fontSize: 30, fontWeight: FontWeight.w700, color: Color(0xFFFFD740))),
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

  // ── MOB ───────────────────────────────────────────────────────────────────
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

    // The entire card is the hold target. Listener reacts to raw pointer
    // events — no GestureDetector delay, no gesture-arena conflicts.
    return Listener(
      onPointerDown: (_) => _startMobClear(),
      onPointerUp: (_) => _cancelMobClear(),
      onPointerCancel: (_) => _cancelMobClear(),
      child: CustomPaint(
        painter: _MobBorderPainter(_clearProgress),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Bearing row ────────────────────────────────────────────
              Row(children: [
                ArrowWidget(bearingDeg: b, color: const Color(0xFFFF5252), size: 60),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                ]),
              ]),
              // ── MOB point coordinates ──────────────────────────────────
              const SizedBox(height: 6),
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
              // ── Hold-to-clear hint ─────────────────────────────────────
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'HOLD 3s TO CLEAR',
                  style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF4A1A1A),
                      letterSpacing: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── MOB card border painter ────────────────────────────────────────────────────
//
// At rest   : thin dim-red rounded-rect outline.
// On hold   : bright red arc fills the border clockwise from the top-left
//             corner; stroke thickens so progress is clearly visible.
//
class _MobBorderPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0

  const _MobBorderPainter(this.progress);

  static const _trackWidth = 1.5;
  static const _arcWidth = 5.5;
  static const _borderRadius = Radius.circular(6.0);

  @override
  void paint(Canvas canvas, Size size) {
    // Inset so the thick arc is never clipped by widget bounds.
    const inset = _arcWidth / 2 + 1.0;
    final rrect = RRect.fromLTRBR(
      inset, inset, size.width - inset, size.height - inset, _borderRadius);

    // ── Background track (always drawn) ────────────────────────────────────
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _trackWidth
        ..color = progress > 0
            ? const Color(0xFF4A1515) // slightly lighter while holding
            : const Color(0xFF3D1212),
    );

    if (progress <= 0) return;

    // ── Progress arc (clockwise fill) ──────────────────────────────────────
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final arc = metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0));

    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _arcWidth
        ..color = Color.lerp(
            const Color(0xFFFF3333), const Color(0xFFFF6666), progress)!
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_MobBorderPainter old) => old.progress != progress;
}
