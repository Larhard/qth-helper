import 'package:xml/xml.dart';
import '../models/waypoint.dart';

/// GPX 1.1 import / export utilities.
///
/// Import:
///   - Only `<wpt>` elements are processed.  Track points (`<trkpt>`),
///     route points (`<rtept>`), and all other elements are ignored so
///     importing a Strava/Komoot export never produces hundreds of spurious
///     waypoints.
///
/// Export:
///   - Generates well-formed GPX 1.1 using the xml library so special
///     characters in waypoint names are automatically escaped.

class GpxUtils {
  GpxUtils._();

  // ── Parse ─────────────────────────────────────────────────────────────────

  /// Parses a GPX string and returns all `<wpt>` elements.
  /// Throws [XmlParserException] if the XML is malformed.
  static List<GpxWaypoint> parse(String content) {
    final document = XmlDocument.parse(content);
    final result   = <GpxWaypoint>[];

    for (final wpt in document.findAllElements('wpt')) {
      final lat = double.tryParse(wpt.getAttribute('lat') ?? '');
      final lon = double.tryParse(wpt.getAttribute('lon') ?? '');
      if (lat == null || lon == null) continue;

      // innerText handles entities (&amp; &lt; …) and CDATA automatically.
      final name    = wpt.getElement('name')?.innerText.trim() ?? 'WPT';
      final timeStr = wpt.getElement('time')?.innerText.trim();
      final time    = (timeStr != null ? DateTime.tryParse(timeStr) : null)
          ?? DateTime.now();

      result.add(GpxWaypoint(name: name, lat: lat, lon: lon, time: time));
    }
    return result;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  /// Builds a GPX 1.1 string from a list of waypoints.
  static String build(List<Waypoint> waypoints) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('gpx', attributes: {
      'version': '1.1',
      'creator': 'QTH Dashboard',
      'xmlns': 'http://www.topografix.com/GPX/1/1',
    }, nest: () {
      for (final w in waypoints) {
        builder.element('wpt', attributes: {
          'lat': w.lat.toStringAsFixed(6),
          'lon': w.lon.toStringAsFixed(6),
        }, nest: () {
          builder.element('name', nest: () => builder.text(w.name));
          builder.element('time',
              nest: () => builder.text(w.timestamp.toUtc().toIso8601String()));
        });
      }
    });
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }
}

/// Parsed waypoint record from a GPX file.
class GpxWaypoint {
  final String   name;
  final double   lat;
  final double   lon;
  final DateTime time;

  const GpxWaypoint({
    required this.name,
    required this.lat,
    required this.lon,
    required this.time,
  });
}
