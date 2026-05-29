String formatLat(double lat) {
  final dir = lat >= 0 ? 'N' : 'S';
  final abs = lat.abs();
  final deg = abs.truncate();
  final min = (abs - deg) * 60;
  return "${deg.toString().padLeft(2, '0')}° ${min.toStringAsFixed(3)}' $dir";
}

String formatLon(double lon) {
  final dir = lon >= 0 ? 'E' : 'W';
  final abs = lon.abs();
  final deg = abs.truncate();
  final min = (abs - deg) * 60;
  return "${deg.toString().padLeft(3, '0')}° ${min.toStringAsFixed(3)}' $dir";
}

/// Calculates 8-character Maidenhead/IARU locator (e.g. JO62mm80).
String maidenhead(double lat, double lon) {
  final normLon = lon + 180.0;
  final normLat = lat + 90.0;

  final fLon = (normLon / 20).floor();
  final fLat = (normLat / 10).floor();
  final rLon = normLon - fLon * 20;
  final rLat = normLat - fLat * 10;

  final sLon = (rLon / 2).floor();
  final sLat = rLat.floor();
  final r2Lon = rLon - sLon * 2.0;
  final r2Lat = rLat - sLat.toDouble();

  final subLon = (r2Lon * 12).floor();
  final subLat = (r2Lat * 24).floor();
  final r3Lon = r2Lon - subLon / 12.0;
  final r3Lat = r2Lat - subLat / 24.0;

  final extLon = (r3Lon * 120).floor() % 10;
  final extLat = (r3Lat * 240).floor() % 10;

  const A = 65; // 'A'
  const a = 97; // 'a'

  return '${String.fromCharCode(A + fLon)}${String.fromCharCode(A + fLat)}'
      '$sLon$sLat'
      '${String.fromCharCode(a + subLon)}${String.fromCharCode(a + subLat)}'
      '$extLon$extLat';
}
