import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../models/city.dart';
import '../services/city_service.dart';
import '../utils/coordinate_utils.dart';
import '../utils/geo_utils.dart';
import '../widgets/arrow_widget.dart';
import '../services/declination_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // GPS speed threshold above which GPS course is used instead of compass.
  // 1.5 m/s ≈ 5.4 km/h — reliable GPS course, filters stationary/walking noise.
  static const _gpsThresholdMs = 1.5;

  Position? _position;
  double _compassHeading = 0; // magnetic + declination
  NearestCity? _nearestCity;
  ({double lat, double lon})? _mob;
  String? _error;

  /// True-north heading from the best available source.
  double get _heading {
    final pos = _position;
    if (pos != null &&
        pos.speed >= _gpsThresholdMs &&
        !pos.heading.isNaN &&
        pos.heading >= 0) {
      return pos.heading; // GPS course is already true north
    }
    return _compassHeading;
  }

  /// Label shown under the heading value.
  String get _headingSource {
    final pos = _position;
    if (pos != null && pos.speed >= _gpsThresholdMs && !pos.heading.isNaN && pos.heading >= 0) {
      return 'TRUE · GPS';
    }
    return 'TRUE · MAG';
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _error = 'Location permission required.\nEnable it in Settings.');
      return;
    }

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      final city = CityService.instance.nearest(pos.latitude, pos.longitude);
      // Update declination in the background; no setState needed here —
      // the value is read on the next compass event rebuild.
      DeclinationService.instance.update(pos.latitude, pos.longitude, pos.altitude);
      setState(() {
        _position = pos;
        _nearestCity = city;
      });
    });

    _compassSub = FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h != null) {
        final corrected = (h + DeclinationService.instance.declination + 360) % 360;
        setState(() => _compassHeading = corrected);
      }
    });
  }

  void _setMob() {
    final pos = _position;
    if (pos == null) return;
    HapticFeedback.heavyImpact();
    setState(() => _mob = (lat: pos.latitude, lon: pos.longitude));
  }

  void _clearMob() => setState(() => _mob = null);

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildError(_error!);
    if (_position == null) return _buildWaiting();
    return _buildMain();
  }

  // ── Waiting / error states ──────────────────────────────────────────────

  Widget _buildWaiting() {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Colors.white24),
          SizedBox(height: 20),
          Text('Acquiring GPS…', style: TextStyle(color: Colors.white38, fontSize: 18)),
        ]),
      ),
    );
  }

  Widget _buildError(String msg) {
    return Scaffold(
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
  }

  // ── Main layout ─────────────────────────────────────────────────────────

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
              _headingSection(),
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

  // ── Heading ─────────────────────────────────────────────────────────────

  Widget _headingSection() {
    return Row(children: [
      ArrowWidget(bearingDeg: _heading, color: Colors.white, size: 80),
      const SizedBox(width: 20),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '${_heading.round()}°',
          style: const TextStyle(
            fontSize: 64,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            height: 1.0,
          ),
        ),
        Text(_headingSource,
            style: const TextStyle(fontSize: 12, color: Color(0xFF444444), letterSpacing: 2.5)),
      ]),
    ]);
  }

  // ── Coordinates ─────────────────────────────────────────────────────────

  Widget _coordsSection(Position pos) {
    const coordStyle = TextStyle(
      fontSize: 30,
      color: Color(0xFF00E5FF),
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(formatLat(pos.latitude), style: coordStyle),
      const SizedBox(height: 2),
      Text(formatLon(pos.longitude), style: coordStyle),
      const SizedBox(height: 10),
      Text(
        maidenhead(pos.latitude, pos.longitude),
        style: const TextStyle(
          fontSize: 28,
          color: Color(0xFF69F0AE),
          fontWeight: FontWeight.w700,
          letterSpacing: 4,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ]);
  }

  // ── Nearest city ─────────────────────────────────────────────────────────

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
              style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 5)),
        ),
      );
    }

    final mob = _mob!;
    final b = bearing(pos.latitude, pos.longitude, mob.lat, mob.lon);
    final d = haversineKm(pos.latitude, pos.longitude, mob.lat, mob.lon);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD32F2F), width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        ArrowWidget(bearingDeg: b, color: const Color(0xFFFF5252), size: 60),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('MOB',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFFFF5252), letterSpacing: 3)),
            Row(children: [
              Text('${b.round()}°',
                  style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFFFF1744),
                      fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(width: 18),
              Text(formatDistance(d),
                  style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFFFF5252),
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ]),
        ),
        TextButton(
          onPressed: _clearMob,
          style: TextButton.styleFrom(foregroundColor: Colors.white30),
          child: const Text('CLEAR', style: TextStyle(fontSize: 13, letterSpacing: 1.5)),
        ),
      ]),
    );
  }
}
