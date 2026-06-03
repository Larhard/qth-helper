import 'gpx_utils.dart';

/// Pure, unit-tested planner for GPX waypoint imports.
///
/// Extracted from WaypointService so the duplicate-detection rules can be tested
/// without GetStorage / platform I/O.  WaypointService calls [plan] then applies
/// the result (assigns IDs, persists, sets NEW/DUPE highlight badges).
///
/// Duplicate rules (base name = the name with any trailing " (N)" suffix removed):
///   • Position AND base-name match → exact duplicate → skipped; the existing
///     point is flagged (DUPE badge).
///   • Position match, different base name → both coexist → imported (NEW).
///   • No position match but base-name conflict → renamed "Base (N)" → imported (NEW).
///   • No conflict → imported as-is (NEW).
class WaypointImporter {
  WaypointImporter._();

  static final _suffix = RegExp(r'\s+\(\d+\)$');

  /// "MOB 1 (2)" → "MOB 1"; "B (3)" → "B"; "B" → "B".
  static String baseName(String name) => name.replaceAll(_suffix, '');

  static WaypointImportPlan plan({
    required List<ExistingWaypoint> existing,
    required List<GpxWaypoint> incoming,
    double tolDeg = 0.0001, // ~10 m
  }) {
    // Mutable working copy so within-batch conflicts are detected too.
    final names = <String>[for (final e in existing) e.name];
    final work  = <ExistingWaypoint>[...existing];

    final toAdd       = <PlannedWaypoint>[];
    final dupExisting = <String>{};
    int skipped = 0, renamed = 0;

    bool samePos(double aLat, double aLon, double bLat, double bLon) =>
        (aLat - bLat).abs() < tolDeg && (aLon - bLon).abs() < tolDeg;

    for (final item in incoming) {
      final baseIn = baseName(item.name);

      // 1. Exact duplicate: position + base-name match → skip, flag existing.
      final exact = work
          .where((e) => samePos(e.lat, e.lon, item.lat, item.lon) &&
                        baseName(e.name) == baseIn)
          .firstOrNull;
      if (exact != null) {
        if (exact.id != null) dupExisting.add(exact.id!);
        skipped++;
        continue;
      }

      // 2. Base-name conflict (any position) → rename "Base (N)".
      var name = item.name;
      if (names.any((n) => baseName(n) == baseIn)) {
        var n = 2;
        while (names.contains('$baseIn ($n)')) {
          n++;
        }
        name = '$baseIn ($n)';
        renamed++;
      }

      toAdd.add(PlannedWaypoint(
          name: name, lat: item.lat, lon: item.lon, time: item.time));
      names.add(name);
      work.add(ExistingWaypoint(id: null, name: name, lat: item.lat, lon: item.lon));
    }

    return WaypointImportPlan(
        toAdd: toAdd, dupExistingIds: dupExisting, skipped: skipped, renamed: renamed);
  }
}

/// An existing waypoint as seen by the planner (id null for within-batch items).
class ExistingWaypoint {
  final String? id;
  final String name;
  final double lat;
  final double lon;
  const ExistingWaypoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });
}

/// A waypoint the planner decided to add (final name, after any rename).
class PlannedWaypoint {
  final String name;
  final double lat;
  final double lon;
  final DateTime time;
  const PlannedWaypoint({
    required this.name,
    required this.lat,
    required this.lon,
    required this.time,
  });
}

class WaypointImportPlan {
  final List<PlannedWaypoint> toAdd;
  final Set<String> dupExistingIds;
  final int skipped;
  final int renamed;
  const WaypointImportPlan({
    required this.toAdd,
    required this.dupExistingIds,
    required this.skipped,
    required this.renamed,
  });
  int get added => toAdd.length;
}
