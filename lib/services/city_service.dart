import 'package:flutter/services.dart';
import '../models/city.dart';
import '../utils/geo_utils.dart';

typedef NearestCity = ({City city, double distKm, double bearingDeg});

enum CityMode { large, precise, detailed }

class CityService {
  CityService._();
  static final instance = CityService._();

  // Grid cell size in degrees. 3° gives ~330 km cells at the equator.
  static const _cellDeg = 3.0;

  Map<int, List<City>> _largeGrid = {};
  Map<int, List<City>> _preciseGrid = {};
  Map<int, List<City>> _detailedGrid = {};
  bool loaded = false;

  CityMode _mode = CityMode.large;
  CityMode get mode => _mode;

  void toggleMode() {
    _mode = switch (_mode) {
      CityMode.large    => CityMode.precise,
      CityMode.precise  => CityMode.detailed,
      CityMode.detailed => CityMode.large,
    };
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  Future<void> load() async {
    if (loaded) return;
    try {
      _largeGrid    = _buildGrid(await _parseTsv('assets/cities.tsv'));
      _preciseGrid  = _buildGrid(await _parseTsv('assets/cities_precise.tsv'));
      _detailedGrid = _buildGrid(await _parseTsv('assets/cities_detailed.tsv'));
      loaded = true;
    } catch (_) {
      // Asset missing — city section stays hidden.
      loaded = false;
    }
  }

  static Future<List<City>> _parseTsv(String asset) async {
    final raw = await rootBundle.loadString(asset);
    final lines = raw.split('\n');
    final cities = <City>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 4) continue;
      final lat = double.tryParse(parts[2]);
      final lon = double.tryParse(parts[3]);
      if (lat == null || lon == null) continue;
      cities.add(City(name: parts[0], country: parts[1], lat: lat, lon: lon));
    }
    return cities;
  }

  // ── Spatial grid ──────────────────────────────────────────────────────────
  // Each city is placed in the grid cell that contains its coordinates.
  // nearest() checks expanding rings of cells until it can guarantee the best
  // result, making lookups O(1) on average regardless of dataset size.

  static int _cellKey(int latBin, int lonBin) =>
      (latBin + 100) * 1000 + (lonBin + 200);

  static Map<int, List<City>> _buildGrid(List<City> cities) {
    final grid = <int, List<City>>{};
    for (final city in cities) {
      final key = _cellKey(
        (city.lat / _cellDeg).floor(),
        (city.lon / _cellDeg).floor(),
      );
      (grid[key] ??= []).add(city);
    }
    return grid;
  }

  // ── Lookup ─────────────────────────────────────────────────────────────────

  NearestCity? nearest(double lat, double lon) {
    final grid = switch (_mode) {
      CityMode.large    => _largeGrid,
      CityMode.precise  => _preciseGrid,
      CityMode.detailed => _detailedGrid,
    };
    if (grid.isEmpty) return null;
    return _nearestInGrid(grid, lat, lon);
  }

  static NearestCity? _nearestInGrid(
      Map<int, List<City>> grid, double lat, double lon) {
    final latBin = (lat / _cellDeg).floor();
    final lonBin = (lon / _cellDeg).floor();

    City? best;
    double bestKm = double.infinity;

    // Expand outward one ring at a time. The perimeter of ring N consists of
    // all cells whose Chebyshev distance from (latBin, lonBin) equals N.
    // Early-exit threshold: 55 km/degree is safe up to ~60° latitude, covering
    // virtually all inhabited areas on Earth.
    for (int ring = 0; ring <= 8; ring++) {
      for (int dlat = -ring; dlat <= ring; dlat++) {
        for (int dlon = -ring; dlon <= ring; dlon++) {
          // Skip cells already checked in previous rings.
          if (ring > 0 && dlat.abs() < ring && dlon.abs() < ring) continue;
          final key = _cellKey(latBin + dlat, lonBin + dlon);
          for (final city in grid[key] ?? const <City>[]) {
            final d = haversineKm(lat, lon, city.lat, city.lon);
            if (d < bestKm) {
              bestKm = d;
              best = city;
            }
          }
        }
      }
      // Minimum possible distance to the nearest edge of the next ring.
      // Using 55 km/° guarantees correctness below ~60° latitude.
      if (best != null && bestKm < ring * _cellDeg * 55.0) break;
    }

    if (best == null) return null;
    return (
      city: best,
      distKm: bestKm,
      bearingDeg: bearing(lat, lon, best.lat, best.lon),
    );
  }
}
