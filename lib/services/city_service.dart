import 'package:flutter/services.dart';
import '../models/city.dart';
import '../utils/geo_utils.dart';

typedef NearestCity = ({City city, double distKm, double bearingDeg});

class CityService {
  CityService._();
  static final instance = CityService._();

  List<City> _cities = [];
  bool loaded = false;

  Future<void> load() async {
    if (loaded) return;
    try {
      final raw = await rootBundle.loadString('assets/cities.tsv');
      final lines = raw.split('\n');
      _cities = [];
      for (var i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        final parts = line.split('\t');
        if (parts.length < 4) continue;
        final lat = double.tryParse(parts[2]);
        final lon = double.tryParse(parts[3]);
        if (lat == null || lon == null) continue;
        _cities.add(City(name: parts[0], country: parts[1], lat: lat, lon: lon));
      }
      loaded = true;
    } catch (_) {
      // cities.tsv not found — app still works, city section hidden
      loaded = false;
    }
  }

  NearestCity? nearest(double lat, double lon) {
    if (_cities.isEmpty) return null;
    City? best;
    double bestDist = double.infinity;
    for (final city in _cities) {
      final d = haversineKm(lat, lon, city.lat, city.lon);
      if (d < bestDist) {
        bestDist = d;
        best = city;
      }
    }
    if (best == null) return null;
    return (
      city: best,
      distKm: bestDist,
      bearingDeg: bearing(lat, lon, best.lat, best.lon),
    );
  }
}
