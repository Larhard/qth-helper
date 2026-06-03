import 'package:flutter_test/flutter_test.dart';
import 'package:qth_dashboard/utils/gpx_utils.dart';
import 'package:qth_dashboard/utils/waypoint_import.dart';

void main() {
  // Helpers
  ExistingWaypoint ex(String id, String name, double lat, double lon) =>
      ExistingWaypoint(id: id, name: name, lat: lat, lon: lon);
  GpxWaypoint inc(String name, double lat, double lon) =>
      GpxWaypoint(name: name, lat: lat, lon: lon, time: DateTime.utc(2020));

  group('WaypointImporter.baseName', () {
    test('strips trailing numeric suffix', () {
      expect(WaypointImporter.baseName('MOB 1 (2)'), 'MOB 1');
      expect(WaypointImporter.baseName('B (3)'), 'B');
      expect(WaypointImporter.baseName('B'), 'B');
    });

    test('leaves embedded parens that are not a trailing suffix', () {
      expect(WaypointImporter.baseName('Cove (north) 1'), 'Cove (north) 1');
    });
  });

  group('WaypointImporter.plan — fresh import', () {
    test('all new waypoints are added', () {
      final p = WaypointImporter.plan(
        existing: [],
        incoming: [inc('A', 1, 1), inc('B', 2, 2)],
      );
      expect(p.added, 2);
      expect(p.skipped, 0);
      expect(p.renamed, 0);
      expect(p.toAdd.map((e) => e.name), ['A', 'B']);
    });
  });

  group('WaypointImporter.plan — duplicate detection', () {
    test('exact duplicate (same name + position) is skipped and flags existing', () {
      final p = WaypointImporter.plan(
        existing: [ex('id1', 'A', 50.0, 19.0)],
        incoming: [inc('A', 50.0, 19.0)],
      );
      expect(p.added, 0);
      expect(p.skipped, 1);
      expect(p.dupExistingIds, {'id1'});
    });

    test('same position, DIFFERENT name → both coexist (imported as new)', () {
      final p = WaypointImporter.plan(
        existing: [ex('id1', 'A', 50.0, 19.0)],
        incoming: [inc('C', 50.0, 19.0)],
      );
      expect(p.added, 1);
      expect(p.skipped, 0);
      expect(p.toAdd.single.name, 'C');
    });

    test('same name, DIFFERENT position → renamed with suffix', () {
      final p = WaypointImporter.plan(
        existing: [ex('id1', 'B', 50.0, 19.0)],
        incoming: [inc('B', 51.0, 20.0)],
      );
      expect(p.added, 1);
      expect(p.renamed, 1);
      expect(p.toAdd.single.name, 'B (2)');
    });

    test('rename increments past existing suffixes', () {
      final p = WaypointImporter.plan(
        existing: [ex('1', 'B', 50.0, 19.0), ex('2', 'B (2)', 51.0, 20.0)],
        incoming: [inc('B', 52.0, 21.0)],
      );
      expect(p.toAdd.single.name, 'B (3)');
    });
  });

  group("WaypointImporter.plan — the user's worked example", () {
    // Existing:  A@pos1, B@pos2
    // Import:    A@pos1, B@pos3, C@pos2
    // Expect:    A skipped(dup), B@pos3 → "B (2)" new, C@pos2 new
    final pos1 = [50.0, 19.0];
    final pos2 = [51.0, 20.0];
    final pos3 = [52.0, 21.0];

    test('first import behaves as specified', () {
      final p = WaypointImporter.plan(
        existing: [ex('A', 'A', pos1[0], pos1[1]), ex('B', 'B', pos2[0], pos2[1])],
        incoming: [
          inc('A', pos1[0], pos1[1]),
          inc('B', pos3[0], pos3[1]),
          inc('C', pos2[0], pos2[1]),
        ],
      );
      expect(p.skipped, 1);             // A is an exact duplicate
      expect(p.dupExistingIds, {'A'});
      expect(p.added, 2);               // B(2) and C
      expect(p.renamed, 1);             // B renamed
      expect(p.toAdd.map((e) => e.name).toSet(), {'B (2)', 'C'});
    });

    test('re-importing the same file a second time adds nothing', () {
      // State after first import: A@pos1, B@pos2, B (2)@pos3, C@pos2
      final p = WaypointImporter.plan(
        existing: [
          ex('A', 'A', pos1[0], pos1[1]),
          ex('B', 'B', pos2[0], pos2[1]),
          ex('B2', 'B (2)', pos3[0], pos3[1]),
          ex('C', 'C', pos2[0], pos2[1]),
        ],
        incoming: [
          inc('A', pos1[0], pos1[1]),
          inc('B', pos3[0], pos3[1]), // base 'B' + pos3 matches existing 'B (2)'
          inc('C', pos2[0], pos2[1]),
        ],
      );
      expect(p.added, 0);
      expect(p.skipped, 3);
      expect(p.dupExistingIds, {'A', 'B2', 'C'});
    });
  });

  group('WaypointImporter.plan — within-batch conflicts', () {
    test('two same-named incoming at different positions get distinct suffixes', () {
      final p = WaypointImporter.plan(
        existing: [ex('1', 'Spot', 50.0, 19.0)],
        incoming: [inc('Spot', 51.0, 20.0), inc('Spot', 52.0, 21.0)],
      );
      expect(p.toAdd.map((e) => e.name), ['Spot (2)', 'Spot (3)']);
    });

    test('two identical incoming → second is an exact duplicate of the first', () {
      final p = WaypointImporter.plan(
        existing: [],
        incoming: [inc('Dup', 50.0, 19.0), inc('Dup', 50.0, 19.0)],
      );
      expect(p.added, 1);
      expect(p.skipped, 1);
    });
  });
}
