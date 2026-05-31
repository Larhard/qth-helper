import 'units.dart' show CoordFormat;

// ── Legacy helpers (degrees decimal-minutes, used as default) ─────────────

String formatLat(double lat) => formatLatF(lat, CoordFormat.degMinDec);
String formatLon(double lon) => formatLonF(lon, CoordFormat.degMinDec);

// ── Format-aware helpers ───────────────────────────────────────────────────

String formatLatF(double lat, CoordFormat fmt) {
  final dir = lat >= 0 ? 'N' : 'S';
  return _fmt(lat.abs(), fmt, padDeg: 2, dir: dir);
}

String formatLonF(double lon, CoordFormat fmt) {
  final dir = lon >= 0 ? 'E' : 'W';
  return _fmt(lon.abs(), fmt, padDeg: 3, dir: dir);
}

String _fmt(double abs, CoordFormat fmt, {required int padDeg, required String dir}) {
  switch (fmt) {
    case CoordFormat.degMinDec:
      final deg = abs.truncate();
      final min = (abs - deg) * 60;
      return "${deg.toString().padLeft(padDeg, '0')}° ${min.toStringAsFixed(3)}' $dir";
    case CoordFormat.degDec:
      return "${abs.toStringAsFixed(6)}° $dir";
    case CoordFormat.degMinSec:
      final deg = abs.truncate();
      final minRaw = (abs - deg) * 60;
      final minInt = minRaw.truncate();
      final sec = (minRaw - minInt) * 60;
      return "${deg.toString().padLeft(padDeg, '0')}° ${minInt.toString().padLeft(2, '0')}' ${sec.toStringAsFixed(2)}\" $dir";
  }
}

/// Example latitude string for the current format (N/S axis).
String coordLatHint(CoordFormat fmt) {
  switch (fmt) {
    case CoordFormat.degMinDec: return "52° 30.123' N";
    case CoordFormat.degDec:    return '52.502050° N';
    case CoordFormat.degMinSec: return '52° 30\' 07.38" N';
  }
}

/// Example longitude string for the current format (E/W axis).
String coordLonHint(CoordFormat fmt) {
  switch (fmt) {
    case CoordFormat.degMinDec: return "018° 20.456' E";
    case CoordFormat.degDec:    return '18.340167° E';
    case CoordFormat.degMinSec: return '018° 20\' 27.36" E';
  }
}

// Backward-compatible alias.
String coordFormatHint(CoordFormat fmt) => coordLatHint(fmt);

/// Parse a latitude or longitude value from user input.
/// Accepts decimal degrees, DDM, and DMS with N/S/E/W suffix or leading minus.
/// Returns null if the value cannot be parsed or is out of range.
double? parseCoordValue(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  final negative = s.toUpperCase().endsWith('S') ||
      s.toUpperCase().endsWith('W') ||
      s.startsWith('-');

  // Strip direction letters, degree/minute/second symbols, leading minus.
  s = s
      .replaceAll(RegExp(r'[NnSsEeWw]'), '')
      .replaceAll(RegExp(r"""[°'"]+"""), ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (s.isEmpty) return null;

  final parts = s.split(' ').where((p) => p.isNotEmpty).toList();
  double value;
  try {
    if (parts.length == 1) {
      value = double.parse(parts[0]);
    } else if (parts.length == 2) {
      value = double.parse(parts[0]) + double.parse(parts[1]) / 60.0;
    } else {
      value = double.parse(parts[0]) +
          double.parse(parts[1]) / 60.0 +
          double.parse(parts[2]) / 3600.0;
    }
  } catch (_) {
    return null;
  }

  return negative ? -value : value;
}

// ── Maidenhead / IARU locator ─────────────────────────────────────────────

/// 4-char grid (field + square), e.g. "JO62".
String maidenhead4(double lat, double lon) => maidenhead(lat, lon).substring(0, 4);

/// 6-char grid (+ subsquare), e.g. "JO62mm". Standard in VHF/UHF/SHF contests.
String maidenhead6(double lat, double lon) => maidenhead(lat, lon).substring(0, 6);

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
