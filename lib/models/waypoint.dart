class Waypoint {
  final String id;
  String name;
  double lat;
  double lon;
  final DateTime timestamp;
  final bool isEmergency; // true = MOB emergency; false = navigation waypoint

  Waypoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.timestamp,
    this.isEmergency = false,
  });

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isEmergency: j['emer'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lon': lon,
        'ts': timestamp.millisecondsSinceEpoch,
        if (isEmergency) 'emer': true,
      };
}
