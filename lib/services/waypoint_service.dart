import 'package:get_storage/get_storage.dart';
import '../models/waypoint.dart';

class WaypointService {
  WaypointService._();
  static final instance = WaypointService._();

  static final _store = GetStorage();
  static const _listKey = 'waypoints';
  static const _activeKey = 'active_waypoint';

  final List<Waypoint> _waypoints = [];
  String? _activeId;

  List<Waypoint> get waypoints => List.unmodifiable(_waypoints);
  String? get activeId => _activeId;

  Waypoint? get active {
    if (_activeId == null) return null;
    for (final w in _waypoints) {
      if (w.id == _activeId) return w;
    }
    return null;
  }

  void load() {
    final raw = _store.read<List>(_listKey) ?? [];
    _waypoints.clear();
    for (final e in raw) {
      try {
        _waypoints.add(Waypoint.fromJson(Map<String, dynamic>.from(e as Map)));
      } catch (_) {}
    }
    _activeId = _store.read<String>(_activeKey);
    // Purge stale active ID
    if (_activeId != null && !_waypoints.any((w) => w.id == _activeId)) {
      _activeId = null;
      _store.remove(_activeKey);
    }
  }

  Waypoint add(double lat, double lon) {
    final w = Waypoint(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'WPT ${_waypoints.length + 1}',
      lat: lat,
      lon: lon,
      timestamp: DateTime.now(),
    );
    _waypoints.insert(0, w);
    _activeId = w.id;
    _persist();
    _store.write(_activeKey, _activeId);
    return w;
  }

  // Add manually entered waypoint (from the waypoints screen).
  Waypoint addManual(String name, double lat, double lon) {
    final w = Waypoint(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? 'WPT ${_waypoints.length + 1}' : name.trim(),
      lat: lat,
      lon: lon,
      timestamp: DateTime.now(),
    );
    _waypoints.insert(0, w);
    _persist();
    return w;
  }

  void setActive(String id) {
    if (_waypoints.any((w) => w.id == id)) {
      _activeId = id;
      _store.write(_activeKey, id);
    }
  }

  void deactivate() {
    _activeId = null;
    _store.remove(_activeKey);
  }

  void remove(String id) {
    _waypoints.removeWhere((w) => w.id == id);
    if (_activeId == id) {
      _activeId = null;
      _store.remove(_activeKey);
    }
    _persist();
  }

  void rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final w in _waypoints) {
      if (w.id == id) {
        w.name = trimmed;
        _persist();
        return;
      }
    }
  }

  void updateCoords(String id, double lat, double lon) {
    for (final w in _waypoints) {
      if (w.id == id) {
        w.lat = lat;
        w.lon = lon;
        _persist();
        return;
      }
    }
  }

  void _persist() {
    _store.write(_listKey, _waypoints.map((w) => w.toJson()).toList());
  }
}
