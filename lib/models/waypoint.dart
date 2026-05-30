class Waypoint {
  final String id;
  String name;
  double lat;
  double lon;
  final DateTime timestamp;

  Waypoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.timestamp,
  });

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lon': lon,
        'ts': timestamp.millisecondsSinceEpoch,
      };
}
