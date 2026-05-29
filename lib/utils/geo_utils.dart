import 'dart:math';

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return R * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// Returns bearing in degrees [0, 360) from point 1 to point 2.
double bearing(double lat1, double lon1, double lat2, double lon2) {
  final dLon = _rad(lon2 - lon1);
  final y = sin(dLon) * cos(_rad(lat2));
  final x =
      cos(_rad(lat1)) * sin(_rad(lat2)) - sin(_rad(lat1)) * cos(_rad(lat2)) * cos(dLon);
  return (_deg(atan2(y, x)) + 360) % 360;
}

String formatDistance(double km) {
  if (km < 1.0) return '${(km * 1000).round()} m';
  if (km < 100.0) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

double _rad(double deg) => deg * pi / 180;
double _deg(double rad) => rad * 180 / pi;
