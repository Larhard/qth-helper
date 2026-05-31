import 'dart:async';
import 'dart:math' show cos, max, min, pi, sin, sqrt;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../services/city_service.dart';
import '../services/declination_service.dart';
import '../utils/coordinate_utils.dart';
import '../utils/geo_utils.dart';
import '../utils/mgrs_utils.dart';
import '../utils/track_bearing.dart';
import '../utils/units.dart';

class DebugScreen extends StatefulWidget {
  final Position? position;
  final double compassHeading;
  final TrackBearingEstimator track;
  final CoordFormat coordFormat;
  final LocatorType locatorType;
  final SpeedUnit speedUnit;
  final bool timeUtc;

  const DebugScreen({
    super.key,
    required this.position,
    required this.compassHeading,
    required this.track,
    required this.coordFormat,
    required this.locatorType,
    required this.speedUnit,
    required this.timeUtc,
  });

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  static const _gnssChannel = EventChannel('qth_helper/gnss');

  // Live data
  Position? _pos;
  double _compassHeading = 0;

  // Satellite data from native EventChannel
  int _satTotal = -1;
  int _satUsed = -1;
  Map<String, int> _satCons = {};

  // Session stats
  int _gpsPktCount = 0;
  DateTime? _sessionStart;

  // Streams — started on open, stopped on close (no main-screen impact)
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription? _gnssSub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _pos = widget.position;
    _compassHeading = widget.compassHeading;
    _sessionStart = DateTime.now();
    _startStreams();
    // Tick every second so time-derived values (elapsed, fix age) stay live.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _startStreams() {
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      if (!mounted) return;
      _gpsPktCount++;
      setState(() => _pos = pos);
    }, onError: (_) {});

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null || !mounted) return;
      final corrected =
          (h + DeclinationService.instance.declination + 360) % 360;
      setState(() => _compassHeading = corrected);
    });

    try {
      _gnssSub = _gnssChannel.receiveBroadcastStream().listen((data) {
        if (!mounted) return;
        final m = Map<String, dynamic>.from(data as Map);
        setState(() {
          _satTotal = (m['total'] as num?)?.toInt() ?? -1;
          _satUsed = (m['used'] as num?)?.toInt() ?? -1;
          _satCons = (m['constellations'] as Map?)
                  ?.map((k, v) => MapEntry(k as String, (v as num).toInt())) ??
              {};
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    _gnssSub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: const Color(0xFF888888),
          elevation: 0,
          title: const Text('Debug',
              style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF555555),
                  letterSpacing: 3,
                  fontWeight: FontWeight.w400)),
          bottom: const TabBar(
            labelColor: Color(0xFF999999),
            unselectedLabelColor: Color(0xFF444444),
            indicatorColor: Color(0xFF555555),
            labelStyle: TextStyle(fontSize: 12, letterSpacing: 1.5),
            tabs: [
              Tab(text: 'GPS'),
              Tab(text: 'HEADING'),
              Tab(text: 'LOCATORS'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_gpsTab(), _headingTab(), _locatorsTab()],
        ),
      ),
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────

  static const _pad = EdgeInsets.fromLTRB(16, 0, 16, 32);

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF555555),
                letterSpacing: 2.5,
                fontWeight: FontWeight.w700)),
      );

  Widget _divider() =>
      const Divider(color: Color(0xFF111111), height: 1, thickness: 1);

  Widget _row(String label, String value,
      {Color? vc, bool mono = true, VoidCallback? onTap}) {
    final text = Text(value,
        textAlign: TextAlign.right,
        style: TextStyle(
            fontSize: 12,
            color: vc ?? const Color(0xFFCCCCCC),
            fontFeatures:
                mono ? const [FontFeature.tabularFigures()] : null));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF666666))),
            const SizedBox(width: 16),
            Flexible(child: text),
          ],
        ),
      ),
    );
  }

  void _copySnack(String value) {
    Clipboard.setData(ClipboardData(text: value));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied: $value',
          style: const TextStyle(color: Colors.white60, fontSize: 12)),
      backgroundColor: const Color(0xFF1C1C1C),
      duration: const Duration(milliseconds: 1200),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  // ── GPS tab ───────────────────────────────────────────────────────────────

  Widget _gpsTab() {
    final pos = _pos;
    final now = DateTime.now();
    final decl = DeclinationService.instance.declination;

    Color accColor(double acc) => acc < 8
        ? const Color(0xFF55DD55)
        : acc < 25
            ? const Color(0xFFFFD740)
            : const Color(0xFFFF7043);

    return SingleChildScrollView(
      padding: _pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Fix ────────────────────────────────────────────────────────────
        _section('Fix'),
        _divider(),
        if (pos == null) ...[
          _row('Status', 'No fix', vc: const Color(0xFFFF5252)),
        ] else ...[
          _row('Horiz. accuracy', '± ${pos.accuracy.toStringAsFixed(1)} m',
              vc: accColor(pos.accuracy)),
          _row('Vert. accuracy',
              '± ${pos.altitudeAccuracy.toStringAsFixed(1)} m'),
          _row('Fix age',
              formatElapsed(now.difference(pos.timestamp))),
          _row('GPS timestamp', _fmtDt(pos.timestamp.toUtc())),
          _row('Mocked', pos.isMocked ? 'YES' : 'no',
              vc: pos.isMocked ? const Color(0xFFFF5252) : null),
        ],

        // ── Satellites ─────────────────────────────────────────────────────
        _section('Satellites'),
        _divider(),
        if (_satTotal < 0)
          _row('GNSS data', 'Awaiting…',
              vc: const Color(0xFF555555))
        else ...[
          _row('Total visible', '$_satTotal'),
          _row('Used in fix', '$_satUsed',
              vc: _satUsed > 3
                  ? const Color(0xFF55DD55)
                  : _satUsed > 0
                      ? const Color(0xFFFFD740)
                      : const Color(0xFFFF5252)),
          ..._satCons.entries
              .toList()
              .sorted((a, b) => b.value.compareTo(a.value))
              .map((e) => _row(e.key, '${e.value}')),
        ],

        // ── Position ───────────────────────────────────────────────────────
        _section('Position'),
        _divider(),
        if (pos == null)
          _row('', '—')
        else ...[
          _row('Latitude',
              formatLatF(pos.latitude, CoordFormat.degMinDec)),
          _row('Longitude',
              formatLonF(pos.longitude, CoordFormat.degMinDec)),
          _row('Altitude',
              '${pos.altitude.toStringAsFixed(1)} m  /  ${(pos.altitude * 3.28084).toStringAsFixed(0)} ft'),
        ],

        // ── Motion ─────────────────────────────────────────────────────────
        _section('Motion'),
        _divider(),
        if (pos == null)
          _row('', '—')
        else ...[
          _row('Speed (km/h)',
              (pos.speed * 3.6).toStringAsFixed(3)),
          _row('Speed (kn)',
              (pos.speed * 1.94384).toStringAsFixed(3)),
          _row('Speed (mph)',
              (pos.speed * 2.23694).toStringAsFixed(3)),
          _row('Speed accuracy',
              '± ${(pos.speedAccuracy * 3.6).toStringAsFixed(2)} km/h'),
          _row('GPS course',
              pos.heading.isNaN || pos.heading < 0
                  ? '—'
                  : '${pos.heading.toStringAsFixed(2)}°'),
          _row('Course accuracy',
              pos.headingAccuracy < 0 || pos.headingAccuracy.isNaN
                  ? '—'
                  : '± ${pos.headingAccuracy.toStringAsFixed(1)}°'),
        ],

        // ── Time ───────────────────────────────────────────────────────────
        _section('Time'),
        _divider(),
        _row('Device (UTC)', _fmtDt(now.toUtc())),
        if (pos != null) ...[
          _row('GPS (UTC)', _fmtDt(pos.timestamp.toUtc())),
          _row('Clock offset', _fmtOffset(pos.timestamp.difference(now))),
          _row('Declination', _fmtDecl(decl)),
        ],

        // ── Session ────────────────────────────────────────────────────────
        _section('Debug session'),
        _divider(),
        _row('GPS packets', '$_gpsPktCount'),
        if (_sessionStart != null && _gpsPktCount > 0)
          _row('Update rate', () {
            final secs =
                now.difference(_sessionStart!).inSeconds.clamp(1, 1 << 30);
            return '${(_gpsPktCount / secs * 60).toStringAsFixed(1)} pkt/min';
          }()),
        _row('Session age', _sessionStart == null
            ? '—'
            : formatElapsed(now.difference(_sessionStart!))),
      ]),
    );
  }

  // ── Heading tab ───────────────────────────────────────────────────────────

  Widget _headingTab() {
    final pos = _pos;
    final decl = DeclinationService.instance.declination;
    final track = widget.track;

    // Raw compass (mag north)
    final rawCompass = (_compassHeading - decl + 360) % 360;

    String deg(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}°';

    return SingleChildScrollView(
      padding: _pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Bearings comparison ────────────────────────────────────────────
        _section('Bearings'),
        _divider(),
        _row('GPS course (true N)',
            pos != null && !pos.heading.isNaN && pos.heading >= 0
                ? deg(pos.heading)
                : '— (speed too low)',
            vc: const Color(0xFF55DD55)),
        _row('Compass (mag N)', deg(rawCompass),
            vc: Colors.white),
        _row('Compass (true N)', deg(_compassHeading),
            vc: const Color(0xFFCCCCCC)),
        _row('TRK smoothed (true N)', deg(track.bearing),
            vc: const Color(0xFFFFD740)),

        // ── Declination ────────────────────────────────────────────────────
        _section('Magnetic field'),
        _divider(),
        _row('Declination', _fmtDecl(decl)),
        _row('Model', 'Android WMM'),
        if (pos != null) ...[
          _row('Computed at',
              '${formatLatF(pos.latitude, CoordFormat.degMinDec)}  ${formatLonF(pos.longitude, CoordFormat.degMinDec)}'),
          _row('Altitude used', '${pos.altitude.toStringAsFixed(0)} m'),
        ],

        // ── TRK buffer ─────────────────────────────────────────────────────
        _section('TRK buffer'),
        _divider(),
        _row('Points', '${track.bufferCount} / ${track.maxSize}'),
        _row('Span', track.spanMetres != null
            ? '${track.spanMetres!.toStringAsFixed(0)} m'
            : '—'),
        _row('Min separation', '${track.minSepM.toStringAsFixed(0)} m'),
        _row('Slide threshold', '${track.maxSpanM.toStringAsFixed(0)} m'),
        const SizedBox(height: 12),
        Center(
          child: _TrackBufferCanvas(
            buffer: track.buffer,
            bearing: track.bearing,
          ),
        ),

        // ── Compass ────────────────────────────────────────────────────────
        _section('Compass stream'),
        _divider(),
        _row('Source', 'flutter_compass'),
        _row('Raw heading', deg(rawCompass)),
        _row('Corrected', deg(_compassHeading)),
        _row('Declination applied', _fmtDecl(decl)),
      ]),
    );
  }

  // ── Locators tab ──────────────────────────────────────────────────────────

  Widget _locatorsTab() {
    final pos = _pos;
    if (pos == null) {
      return const Center(
        child: Text('Waiting for GPS fix…',
            style: TextStyle(color: Color(0xFF555555), fontSize: 15)),
      );
    }
    final lat = pos.latitude;
    final lon = pos.longitude;
    final mh8 = maidenhead(lat, lon);
    final mh6 = mh8.substring(0, 6);
    final mh4 = mh8.substring(0, 4);
    final mgrsStr = mgrs(lat, lon);
    final geoUri = 'geo:${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

    return SingleChildScrollView(
      padding: _pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Coordinates ────────────────────────────────────────────────────
        _section('Coordinates'),
        _divider(),
        _row('DDM',
            '${formatLatF(lat, CoordFormat.degMinDec)}  ${formatLonF(lon, CoordFormat.degMinDec)}',
            onTap: () => _copySnack(
                '${formatLatF(lat, CoordFormat.degMinDec)}\n${formatLonF(lon, CoordFormat.degMinDec)}')),
        _row('DD',
            '${formatLatF(lat, CoordFormat.degDec)}  ${formatLonF(lon, CoordFormat.degDec)}',
            onTap: () => _copySnack(
                '${formatLatF(lat, CoordFormat.degDec)}\n${formatLonF(lon, CoordFormat.degDec)}')),
        _row('DMS',
            '${formatLatF(lat, CoordFormat.degMinSec)}  ${formatLonF(lon, CoordFormat.degMinSec)}',
            onTap: () => _copySnack(
                '${formatLatF(lat, CoordFormat.degMinSec)}\n${formatLonF(lon, CoordFormat.degMinSec)}')),
        _row('Decimal', '${lat.toStringAsFixed(7)}, ${lon.toStringAsFixed(7)}',
            onTap: () => _copySnack(
                '${lat.toStringAsFixed(7)}, ${lon.toStringAsFixed(7)}')),

        // ── Locators ───────────────────────────────────────────────────────
        _section('Locators'),
        _divider(),
        _row('Maidenhead 8 (1 km)', mh8,
            vc: const Color(0xFF55DD55),
            onTap: () => _copySnack(mh8)),
        _row('Maidenhead 6 (12 km)', mh6,
            vc: const Color(0xFF69F0AE),
            onTap: () => _copySnack(mh6)),
        _row('Maidenhead 4 (field)', mh4,
            vc: const Color(0xFF80CBC4),
            onTap: () => _copySnack(mh4)),
        _row('MGRS', mgrsStr,
            vc: const Color(0xFFFFA726),
            onTap: () => _copySnack(mgrsStr)),

        // ── URI / links ────────────────────────────────────────────────────
        _section('URIs  (tap to copy)'),
        _divider(),
        _row('geo:', geoUri, onTap: () => _copySnack(geoUri)),
        _row('OSM', 'https://osm.org/?mlat=${lat.toStringAsFixed(6)}&mlon=${lon.toStringAsFixed(6)}',
            onTap: () => _copySnack(
                'https://osm.org/?mlat=${lat.toStringAsFixed(6)}&mlon=${lon.toStringAsFixed(6)}')),

        // ── Cities — all modes ─────────────────────────────────────────────
        _section('Nearest city — all precision levels'),
        _divider(),
        ..._cityRows(lat, lon),
      ]),
    );
  }

  List<Widget> _cityRows(double lat, double lon) {
    final labels = {
      CityMode.large: 'Large (global)',
      CityMode.precise: 'Precise (regional)',
      CityMode.detailed: 'Detailed (local)',
    };
    final colors = {
      CityMode.large: const Color(0xFFFF9800),
      CityMode.precise: const Color(0xFFFFD740),
      CityMode.detailed: const Color(0xFFC6FF00),
    };
    final rows = <Widget>[];
    for (final mode in CityMode.values) {
      final nc = CityService.instance.nearestForMode(lat, lon, mode);
      final value = nc == null
          ? '—'
          : '${nc.city.name}  →  ${nc.bearingDeg.round()}°  ${formatDistance(nc.distKm)}';
      rows.add(_row(labels[mode]!, value, vc: colors[mode]));
    }
    return rows;
  }

  // ── Static formatters ─────────────────────────────────────────────────────

  static String _fmtDt(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${(dt.millisecond ~/ 10).toString().padLeft(2, '0')} UTC';
  }

  static String _fmtOffset(Duration d) {
    final ms = d.inMilliseconds;
    final sign = ms >= 0 ? '+' : '−';
    return '$sign${ms.abs()} ms';
  }

  static String _fmtDecl(double decl) {
    final dir = decl >= 0 ? 'E' : 'W';
    return '${decl.abs().toStringAsFixed(2)}° $dir';
  }
}

// ── TRK buffer visualisation ──────────────────────────────────────────────────

class _TrackBufferCanvas extends StatelessWidget {
  final List<({double lat, double lon})> buffer;
  final double? bearing;

  const _TrackBufferCanvas({required this.buffer, this.bearing});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 160,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        border: Border.all(color: const Color(0xFF1E1E1E)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: buffer.length < 2
          ? const Center(
              child: Text('No data',
                  style: TextStyle(color: Color(0xFF333333), fontSize: 12)))
          : CustomPaint(painter: _BufferPainter(buffer, bearing)),
    );
  }
}

class _BufferPainter extends CustomPainter {
  final List<({double lat, double lon})> buffer;
  final double? bearing;

  const _BufferPainter(this.buffer, this.bearing);

  @override
  void paint(Canvas canvas, Size size) {
    if (buffer.length < 2) return;

    final cx = size.width / 2;
    final cy = size.height / 2;

    // Newest point is centre; older points are plotted relative to it so the
    // canvas shows "where we came from" radiating out from the current position.
    final refLat = buffer.last.lat;
    final refLon = buffer.last.lon;
    final cosLat = cos(refLat * pi / 180);

    final pts = buffer.map((p) {
      final dx = (p.lon - refLon) * 111320.0 * cosLat;
      final dy = -(p.lat - refLat) * 111320.0; // flip Y: lat↑ = screen↓
      return Offset(dx, dy);
    }).toList();

    // Scale to fit with padding.
    var maxR = 1.0;
    for (final p in pts) {
      maxR = max(maxR, sqrt(p.dx * p.dx + p.dy * p.dy));
    }
    final pad = 18.0;
    final scale = (min(size.width, size.height) / 2 - pad) / maxR;
    Offset s(Offset p) => Offset(cx + p.dx * scale, cy + p.dy * scale);

    // Trail lines
    final linePaint = Paint()
      ..color = const Color(0xFF2A2A2A)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (int i = 1; i < pts.length; i++) {
      canvas.drawLine(s(pts[i - 1]), s(pts[i]), linePaint);
    }

    // Dots — oldest dim/small → newest bright/large
    for (int i = 0; i < pts.length; i++) {
      final t = i / (pts.length - 1).toDouble();
      final colour =
          Color.lerp(const Color(0xFF2A3A2A), const Color(0xFF00BCD4), t)!;
      canvas.drawCircle(s(pts[i]), 2.5 + t * 3.5, Paint()..color = colour);
    }

    // Current position (newest = centre)
    canvas.drawCircle(Offset(cx, cy), 7,
        Paint()..color = const Color(0xFF00BCD4).withValues(alpha: 0.25));
    canvas.drawCircle(Offset(cx, cy), 4,
        Paint()..color = const Color(0xFF00BCD4));

    // Bearing arrow (green, from centre in direction of travel)
    if (bearing != null) {
      final bRad = bearing! * pi / 180;
      final arrowLen = min(cx, cy) - pad - 4;
      final tipX = cx + sin(bRad) * arrowLen;
      final tipY = cy - cos(bRad) * arrowLen;
      canvas.drawLine(
        Offset(cx, cy),
        Offset(tipX, tipY),
        Paint()
          ..color = const Color(0xFF55DD55)
          ..strokeWidth = 1.5,
      );
      // Arrowhead
      const aw = 5.0;
      final ax = bRad + pi * 0.8;
      final ay = bRad - pi * 0.8;
      canvas.drawLine(
        Offset(tipX, tipY),
        Offset(tipX + sin(ax) * aw, tipY - cos(ax) * aw),
        Paint()..color = const Color(0xFF55DD55)..strokeWidth = 1.5,
      );
      canvas.drawLine(
        Offset(tipX, tipY),
        Offset(tipX + sin(ay) * aw, tipY - cos(ay) * aw),
        Paint()..color = const Color(0xFF55DD55)..strokeWidth = 1.5,
      );
    }

    // North indicator (small N at top edge)
    final nPaint = Paint()
      ..color = const Color(0xFF333333)
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(cx, pad - 4), Offset(cx, pad + 8), nPaint);
  }

  @override
  bool shouldRepaint(_BufferPainter old) =>
      old.buffer != buffer || old.bearing != bearing;
}

// Extension to sort MapEntry lists
extension _Sorted<T> on List<T> {
  List<T> sorted(int Function(T, T) compare) => [...this]..sort(compare);
}
