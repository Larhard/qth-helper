import 'package:flutter_test/flutter_test.dart';
import 'package:qth_dashboard/utils/gpx_utils.dart';
import 'package:qth_dashboard/models/waypoint.dart';

void main() {
  group('GpxUtils.parse — waypoint extraction', () {
    test('parses a basic waypoint', () {
      const gpx = '''
<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="50.0647" lon="19.9450"><name>Summit</name></wpt>
</gpx>''';
      final r = GpxUtils.parse(gpx);
      expect(r.length, 1);
      expect(r.first.name, 'Summit');
      expect(r.first.lat, closeTo(50.0647, 1e-6));
      expect(r.first.lon, closeTo(19.9450, 1e-6));
    });

    test('IGNORES track points and route points (no spam from Strava exports)', () {
      const gpx = '''
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="1.0" lon="2.0"><name>Keep me</name></wpt>
  <trk><trkseg>
    <trkpt lat="3.0" lon="4.0"></trkpt>
    <trkpt lat="3.1" lon="4.1"></trkpt>
  </trkseg></trk>
  <rte><rtept lat="5.0" lon="6.0"></rtept></rte>
</gpx>''';
      final r = GpxUtils.parse(gpx);
      expect(r.length, 1);
      expect(r.first.name, 'Keep me');
    });

    test('decodes XML entities in names', () {
      const gpx = '''
<gpx xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="1" lon="2"><name>Pier &amp; Dock &lt;3&gt;</name></wpt>
</gpx>''';
      expect(GpxUtils.parse(gpx).first.name, 'Pier & Dock <3>');
    });

    test('handles namespaced and comment-laden GPX', () {
      const gpx = '''
<?xml version="1.0"?>
<!-- exported by some app -->
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="10" lon="20"><name>NS</name><ele>5</ele></wpt>
</gpx>''';
      expect(GpxUtils.parse(gpx).single.name, 'NS');
    });

    test('skips wpt with invalid coordinates', () {
      const gpx = '''
<gpx xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="abc" lon="20"><name>Bad</name></wpt>
  <wpt lat="11" lon="21"><name>Good</name></wpt>
</gpx>''';
      final r = GpxUtils.parse(gpx);
      expect(r.length, 1);
      expect(r.single.name, 'Good');
    });

    test('defaults missing name to "WPT"', () {
      const gpx = '<gpx xmlns="http://www.topografix.com/GPX/1/1">'
          '<wpt lat="1" lon="2"></wpt></gpx>';
      expect(GpxUtils.parse(gpx).single.name, 'WPT');
    });

    test('parses ISO-8601 time when present', () {
      const gpx = '''
<gpx xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="1" lon="2"><name>T</name><time>2020-01-02T03:04:05Z</time></wpt>
</gpx>''';
      final w = GpxUtils.parse(gpx).single;
      expect(w.time.toUtc(), DateTime.utc(2020, 1, 2, 3, 4, 5));
    });

    test('throws on malformed XML (caller catches and warns)', () {
      expect(() => GpxUtils.parse('<gpx><wpt lat='), throwsA(anything));
    });
  });

  group('GpxUtils.build — round trip', () {
    test('builds valid GPX that re-parses to the same waypoints', () {
      final original = [
        Waypoint(id: '1', name: 'Alpha', lat: 50.5, lon: 19.5,
            timestamp: DateTime.utc(2021, 6, 1, 12)),
        Waypoint(id: '2', name: 'Bravo & Co <test>', lat: -33.87, lon: 151.21,
            timestamp: DateTime.utc(2022, 7, 2, 8, 30)),
      ];
      final gpx = GpxUtils.build(original);
      final parsed = GpxUtils.parse(gpx);

      expect(parsed.length, 2);
      expect(parsed[0].name, 'Alpha');
      expect(parsed[0].lat, closeTo(50.5, 1e-6));
      expect(parsed[1].name, 'Bravo & Co <test>'); // entities survived round-trip
      expect(parsed[1].lon, closeTo(151.21, 1e-6));
    });

    test('produces a well-formed XML declaration and gpx root', () {
      final gpx = GpxUtils.build([
        Waypoint(id: '1', name: 'X', lat: 1, lon: 2, timestamp: DateTime.utc(2020)),
      ]);
      expect(gpx, contains('<?xml'));
      expect(gpx, contains('<gpx'));
      expect(gpx, contains('creator="QTH Dashboard"'));
    });
  });
}
