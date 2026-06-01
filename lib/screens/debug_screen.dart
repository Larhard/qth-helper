import 'dart:async';
import 'dart:math' show acos, atan2, cos, log, max, min, pi, pow, sin, sqrt;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../services/city_service.dart';
import '../services/environment_service.dart';
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
  final bool dayMode;

  const DebugScreen({
    super.key,
    required this.position,
    required this.compassHeading,
    required this.track,
    required this.coordFormat,
    required this.locatorType,
    required this.speedUnit,
    required this.timeUtc,
    required this.dayMode,
  });

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  static const _gnssChannel = EventChannel('qth_helper/gnss');

  // Live data
  Position? _pos;
  // Device clock sampled at the exact moment each GPS packet is received.
  // Differencing this against pos.timestamp gives true clock skew (GPS − device).
  DateTime? _deviceTimeAtFix;
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
  StreamSubscription? _envSub;
  Map<String, dynamic> _env = {};
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
      // Sample device clock the instant the packet arrives so the difference
      // against pos.timestamp is true GPS–device clock skew, not fix age.
      final deviceNow = DateTime.now();
      setState(() {
        _pos = pos;
        _deviceTimeAtFix = deviceNow;
      });
    }, onError: (_) {});

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null || !mounted) return;
      final corrected =
          (h + DeclinationService.instance.declination + 360) % 360;
      setState(() => _compassHeading = corrected);
    });

    _envSub = EnvironmentService.instance.stream.listen((data) {
      if (!mounted) return;
      setState(() => _env = data);
    }, onError: (_) {});

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
    _envSub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: _cHead,
          elevation: 0,
          title: Text('Debug',
              style: TextStyle(
                  fontSize: 15,
                  color: _cHead,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w400)),
          bottom: TabBar(
            labelColor: _cText,
            unselectedLabelColor: _cDim,
            indicatorColor: _cHead,
            dividerColor: _cDim,
            labelStyle: TextStyle(fontSize: 12, letterSpacing: 1.5),
            tabs: [
              Tab(text: 'GPS'),
              Tab(text: 'HEADING'),
              Tab(text: 'LOCATORS'),
              Tab(text: 'SENSORS'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_gpsTab(), _headingTab(), _locatorsTab(), _sensorsTab()],
        ),
      ),
    );
  }

  // ── Palette (day / night) ─────────────────────────────────────────────────
  bool get _day => widget.dayMode;
  Color get _cText  => _day ? kDFg0   : kN1;
  Color get _cLabel => _day ? kDFg3   : kN2;
  Color get _cHead  => _day ? kDFg3   : kN2;
  Color get _cGood  => _day ? kDGps   : kN2;
  Color get _cWarn  => _day ? kDCityP : kN2;
  Color get _cBad   => _day ? kDEmg   : kN1;
  Color get _cDim   => _day ? kDFg3   : kN3;

  // ── Shared helpers ────────────────────────────────────────────────────────

  static const _pad = EdgeInsets.fromLTRB(16, 0, 16, 32);

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
        child: Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                color: _cHead,
                letterSpacing: 2.5,
                fontWeight: FontWeight.w700)),
      );

  Widget _divider() => Divider(color: _day ? kDDiv : kNDiv, height: 1, thickness: 1);

  Widget _row(String label, String value,
      {Color? vc, bool mono = true, VoidCallback? onTap}) {
    final text = Text(value,
        textAlign: TextAlign.right,
        style: TextStyle(
            fontSize: 12,
            color: vc ?? _cText,
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
                style: TextStyle(fontSize: 12, color: _cLabel)),
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
          style: TextStyle(color: _day ? kDFg1 : kN2, fontSize: 12)),
      backgroundColor: _day ? kDSnackBg : kNBg,
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
        ? _cGood
        : acc < 25 ? _cWarn : _cBad;

    return SingleChildScrollView(
      padding: _pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Fix ────────────────────────────────────────────────────────────
        _section('Fix'),
        _divider(),
        if (pos == null) ...[
          _row('Status', 'No fix', vc: _cBad),
        ] else ...[
          _row('Horiz. accuracy', '± ${pos.accuracy.toStringAsFixed(1)} m',
              vc: accColor(pos.accuracy)),
          _row('Vert. accuracy',
              '± ${pos.altitudeAccuracy.toStringAsFixed(1)} m'),
          _row('Fix age',
              formatElapsed(now.difference(pos.timestamp))),
          _row('GPS timestamp', _fmtDt(pos.timestamp.toUtc())),
          _row('Mocked', pos.isMocked ? 'YES' : 'no',
              vc: pos.isMocked ? _cBad : null),
        ],

        // ── Satellites ─────────────────────────────────────────────────────
        _section('Satellites'),
        _divider(),
        if (_satTotal < 0)
          _row('GNSS data', 'Awaiting…', vc: _cDim)
        else ...[
          _row('Total visible', '$_satTotal'),
          _row('Used in fix', '$_satUsed',
              vc: _satUsed > 3 ? _cGood : _satUsed > 0 ? _cWarn : _cBad),
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
          _row('Clock skew (GPS−device)',
              _deviceTimeAtFix != null
                  ? _fmtOffset(pos.timestamp.difference(_deviceTimeAtFix!))
                  : 'Awaiting first packet'),
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
            vc: _cGood),
        _row('Compass (mag N)', deg(rawCompass),
            vc: _cText),
        _row('Compass (true N)', deg(_compassHeading)),
        _row('TRK smoothed (true N)', deg(track.bearing),
            vc: _cWarn),

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
            dayMode: _day,
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
      return Center(
        child: Text('Waiting for GPS fix…',
            style: TextStyle(color: _day ? kDFg3 : kN3, fontSize: 15)),
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
            vc: _day ? kDGps   : kN2, onTap: () => _copySnack(mh8)),
        _row('Maidenhead 6 (12 km)', mh6,
            vc: _day ? kDGpsM6 : kN3, onTap: () => _copySnack(mh6)),
        _row('Maidenhead 4 (field)', mh4,
            vc: _day ? kDGpsM4 : kN4, onTap: () => _copySnack(mh4)),
        _row('MGRS', mgrsStr,
            vc: _day ? kDAmb   : kN2, onTap: () => _copySnack(mgrsStr)),

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
      CityMode.large:    'Large (global)',
      CityMode.precise:  'Precise (regional)',
      CityMode.detailed: 'Detailed (local)',
      CityMode.port:     'Port / Harbour',
    };
    final dayColors = {
      CityMode.large:    kDCityL,
      CityMode.precise:  kDCityP,
      CityMode.detailed: kDCityD,
      CityMode.port:     kDPort,
    };
    final rows = <Widget>[];
    for (final mode in CityMode.values) {
      final nc = CityService.instance.nearestForMode(lat, lon, mode);
      final value = nc == null
          ? '—'
          : '${nc.city.name}  →  ${nc.bearingDeg.round()}°  ${formatDistance(nc.distKm)}';
      rows.add(_row(labels[mode]!, value,
          vc: _day ? dayColors[mode] : kN2));
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

  // ── Sensors tab ───────────────────────────────────────────────────────────

  Widget _sensorsTab() {
    final e = _env;
    final avail = ((e['available']) as List?)?.cast<String>().toSet() ?? <String>{};

    // Helper: double from map or null
    double? dv(String k) {
      final v = e[k];
      return v == null ? null : (v as num).toDouble();
    }

    // Format a nullable double; show '—' if null, 'N/A' if sensor absent
    String fmt(double? v, {int dec = 1}) =>
        v == null ? '—' : v.toStringAsFixed(dec);
    String sensor(String key, double? v, {int dec = 1}) =>
        avail.contains(key) ? fmt(v, dec: dec) : 'N/A';

    // ── Temperature ─────────────────────────────────────────────────────────
    final tC = dv('temperature');
    final tF = tC != null ? tC * 9 / 5 + 32 : null;
    final tK = tC != null ? tC + 273.15 : null;

    // ── Pressure & barometric altitude ───────────────────────────────────────
    final hpa = dv('pressure');
    final pa    = hpa != null ? hpa * 100 : null;
    final inHg  = hpa != null ? hpa * 0.02953 : null;
    final mmHg  = hpa != null ? hpa * 0.75006 : null;
    final atm   = hpa != null ? hpa * 0.000987 : null;
    final altM  = hpa != null
        ? 44330.0 * (1.0 - pow(hpa / 1013.25, 0.19029))
        : null;
    final altFt = altM != null ? altM * 3.28084 : null;

    // ── Light ────────────────────────────────────────────────────────────────
    final lux = dv('light');
    final fc  = lux != null ? lux * 0.09290304 : null;
    final ev  = (lux != null && lux > 0) ? log(lux / 2.5) / log(2) : null;

    // ── Magnetic field ───────────────────────────────────────────────────────
    final mx = dv('mag_x');
    final my = dv('mag_y');
    final mz = dv('mag_z');
    final mb = (mx != null && my != null && mz != null)
        ? sqrt(mx * mx + my * my + mz * mz)
        : null;

    // ── Motion ───────────────────────────────────────────────────────────────
    final steps = dv('steps')?.round();
    final distM  = steps != null ? steps * 0.75 : null;
    final distKm = distM != null ? distM / 1000 : null;
    final distMi = distM != null ? distM / 1609.34 : null;

    // ── Battery ──────────────────────────────────────────────────────────────
    final battPct = dv('battery_pct');
    final battC   = dv('battery_temp');
    final battF   = battC != null ? battC * 9 / 5 + 32 : null;
    final battK   = battC != null ? battC + 273.15 : null;

    // Battery level colour
    Color battColor(double? pct) {
      if (pct == null) return _cText;
      if (pct > 50) return _cGood;
      if (pct > 20) return _cWarn;
      return _cBad;
    }

    return SingleChildScrollView(
      padding: _pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Environmental ──────────────────────────────────────────────────
        _section('Environmental'),
        _divider(),
        _row('Temperature  °C', sensor('temperature', tC)),
        _row('Temperature  °F', sensor('temperature', tF)),
        _row('Temperature  K',  sensor('temperature', tK, dec: 2)),
        _row('Pressure  hPa',   sensor('pressure', hpa)),
        if (avail.contains('pressure')) ...[
          _row('Pressure  Pa',    fmt(pa,   dec: 0)),
          _row('Pressure  inHg',  fmt(inHg, dec: 3)),
          _row('Pressure  mmHg',  fmt(mmHg, dec: 1)),
          _row('Pressure  atm',   fmt(atm,  dec: 5)),
          _row('Baro altitude  m',  fmt(altM,  dec: 0)),
          _row('Baro altitude  ft', fmt(altFt, dec: 0)),
        ],
        _row('Humidity  %', sensor('humidity', dv('humidity'))),
        _row('Light  lux', sensor('light', lux, dec: 0)),
        if (avail.contains('light')) ...[
          _row('Light  fc',  fmt(fc, dec: 1)),
          _row('Light  EV',  fmt(ev, dec: 1)),
        ],

        // ── Magnetic field ──────────────────────────────────────────────────
        _section('Magnetic field'),
        _divider(),
        _row('X (north)  µT', avail.contains('magnetic') ? fmt(mx) : 'N/A'),
        _row('Y (east)   µT', avail.contains('magnetic') ? fmt(my) : 'N/A'),
        _row('Z (down)   µT', avail.contains('magnetic') ? fmt(mz) : 'N/A'),
        if (avail.contains('magnetic')) ...[
          _row('|B|  µT',     fmt(mb, dec: 1)),
          _row('|B|  nT',     fmt(mb != null ? mb * 1000 : null, dec: 0)),
          _row('|B|  mGauss', fmt(mb != null ? mb * 10   : null, dec: 0)),
        ],

        // ── Proximity ──────────────────────────────────────────────────────
        _section('Proximity'),
        _divider(),
        () {
          final proxCm  = dv('proximity');
          final proxMax = dv('proximity_max');
          final state   = (proxCm != null && proxMax != null)
              ? (proxCm < proxMax ? 'NEAR' : 'FAR')
              : null;
          final na = avail.contains('proximity') ? null : 'N/A';
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row('Distance  cm', na ?? fmt(proxCm, dec: 1),
                vc: state == 'NEAR' ? _cWarn : null),
            _row('Max range  cm', na ?? fmt(proxMax, dec: 1)),
            _row('State', na ?? (state ?? '—'),
                vc: state == 'NEAR' ? _cWarn : (state == 'FAR' ? _cGood : null)),
          ]);
        }(),

        // ── Gravity / tilt ─────────────────────────────────────────────────
        _section('Gravity / tilt'),
        _divider(),
        () {
          final gx = dv('grav_x');
          final gy = dv('grav_y');
          final gz = dv('grav_z');
          final gMag = (gx != null && gy != null && gz != null)
              ? sqrt(gx * gx + gy * gy + gz * gz) : null;
          // 0° = phone flat (face up/down); 90° = phone vertical.
          final tilt = (gz != null && gMag != null && gMag > 0.01)
              ? acos((gz.abs() / gMag).clamp(0.0, 1.0)) * 180 / pi : null;
          // Pitch: negative = top forward, positive = top backward.
          final pitch = (gy != null && gz != null)
              ? atan2(-gy, gz) * 180 / pi : null;
          // Roll: positive = right, negative = left.
          final roll = (gx != null && gz != null)
              ? atan2(gx, gz) * 180 / pi : null;
          final na = avail.contains('gravity') ? null : 'N/A';
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row('Tilt from horiz  °', na ?? fmt(tilt)),
            _row('Pitch  °',           na ?? fmt(pitch)),
            _row('Roll   °',           na ?? fmt(roll)),
            _row('X  m/s²',            na ?? fmt(gx)),
            _row('Y  m/s²',            na ?? fmt(gy)),
            _row('Z  m/s²',            na ?? fmt(gz)),
            _row('|g|  m/s²',          na ?? fmt(gMag, dec: 3)),
          ]);
        }(),

        // ── Linear acceleration ─────────────────────────────────────────────
        _section('Linear acceleration (gravity removed)'),
        _divider(),
        () {
          final ax = dv('lin_x');
          final ay = dv('lin_y');
          final az = dv('lin_z');
          final aMag = (ax != null && ay != null && az != null)
              ? sqrt(ax * ax + ay * ay + az * az) : null;
          final na = avail.contains('linear_accel') ? null : 'N/A';
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row('X  m/s²',   na ?? fmt(ax)),
            _row('Y  m/s²',   na ?? fmt(ay)),
            _row('Z  m/s²',   na ?? fmt(az)),
            _row('|a|  m/s²', na ?? fmt(aMag, dec: 3)),
          ]);
        }(),

        // ── Motion ─────────────────────────────────────────────────────────
        _section('Motion'),
        _divider(),
        _row('Steps since open',   avail.contains('steps')
            ? (steps?.toString() ?? '—') : 'N/A'),
        if (avail.contains('steps') && steps != null) ...[
          _row('Est. distance  m',  fmt(distM,  dec: 0)),
          _row('Est. distance  km', fmt(distKm, dec: 2)),
          _row('Est. distance  mi', fmt(distMi, dec: 2)),
        ],

        // ── Battery ─────────────────────────────────────────────────────────
        _section('Battery'),
        _divider(),
        _row('Level  %',
            battPct != null ? '${battPct.toStringAsFixed(0)} %' : '—',
            vc: battColor(battPct)),
        _row('Temperature  °C', fmt(battC)),
        _row('Temperature  °F', fmt(battF)),
        _row('Temperature  K',  fmt(battK, dec: 2)),
      ]),
    );
  }
}

// ── TRK buffer visualisation ──────────────────────────────────────────────────

class _TrackBufferCanvas extends StatelessWidget {
  final List<({double lat, double lon})> buffer;
  final double? bearing;
  final bool dayMode;

  const _TrackBufferCanvas({
    required this.buffer,
    this.bearing,
    required this.dayMode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 160,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        border: Border.all(color: dayMode ? kDDiv : kNDiv),
        borderRadius: BorderRadius.circular(4),
      ),
      child: buffer.length < 2
          ? Center(
              child: Text('No data',
                  style: TextStyle(
                      color: dayMode ? kDBrd : kN4,
                      fontSize: 12)))
          : CustomPaint(painter: _BufferPainter(buffer, bearing, dayMode)),
    );
  }
}

class _BufferPainter extends CustomPainter {
  final List<({double lat, double lon})> buffer;
  final double? bearing;
  final bool dayMode;

  const _BufferPainter(this.buffer, this.bearing, this.dayMode);

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

    final dotNew  = dayMode ? kDPortL                : kN1;
    final dotOld  = dayMode ? const Color(0xFF2A3A2A) : kNEmgRingDim;
    final arrow   = dayMode ? kDGps                  : kN1;
    final nMark   = dayMode ? kDBrd                  : kN4;

    // Trail lines
    final linePaint = Paint()
      ..color = dayMode ? kDDiv : kNBg
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (int i = 1; i < pts.length; i++) {
      canvas.drawLine(s(pts[i - 1]), s(pts[i]), linePaint);
    }

    // Dots — oldest dim/small → newest bright/large
    for (int i = 0; i < pts.length; i++) {
      final t = i / (pts.length - 1).toDouble();
      canvas.drawCircle(
          s(pts[i]), 2.5 + t * 3.5,
          Paint()..color = Color.lerp(dotOld, dotNew, t)!);
    }

    // Current position glow + dot
    canvas.drawCircle(Offset(cx, cy), 7,
        Paint()..color = dotNew.withValues(alpha: 0.25));
    canvas.drawCircle(Offset(cx, cy), 4, Paint()..color = dotNew);

    // Bearing arrow from centre in direction of travel
    if (bearing != null) {
      final bRad = bearing! * pi / 180;
      final arrowLen = min(cx, cy) - pad - 4;
      final tipX = cx + sin(bRad) * arrowLen;
      final tipY = cy - cos(bRad) * arrowLen;
      final ap = Paint()..color = arrow..strokeWidth = 1.5;
      canvas.drawLine(Offset(cx, cy), Offset(tipX, tipY), ap);
      const aw = 5.0;
      for (final a in [bRad + pi * 0.8, bRad - pi * 0.8]) {
        canvas.drawLine(Offset(tipX, tipY),
            Offset(tipX + sin(a) * aw, tipY - cos(a) * aw), ap);
      }
    }

    // North tick
    canvas.drawLine(Offset(cx, pad - 4), Offset(cx, pad + 8),
        Paint()..color = nMark..strokeWidth = 1.0);
  }

  @override
  bool shouldRepaint(_BufferPainter old) =>
      old.buffer != buffer || old.bearing != bearing || old.dayMode != dayMode;
}

// Extension to sort MapEntry lists
extension _Sorted<T> on List<T> {
  List<T> sorted(int Function(T, T) compare) => [...this]..sort(compare);
}
