import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../models/waypoint.dart';
import '../services/waypoint_service.dart';
import '../utils/geo_utils.dart';
import '../utils/units.dart';
import '../utils/coordinate_utils.dart';

class WaypointsScreen extends StatefulWidget {
  final Position? currentPosition;
  final SpeedUnit speedUnit;

  const WaypointsScreen({
    super.key,
    required this.currentPosition,
    required this.speedUnit,
  });

  @override
  State<WaypointsScreen> createState() => _WaypointsScreenState();
}

class _WaypointsScreenState extends State<WaypointsScreen> {
  @override
  Widget build(BuildContext context) {
    final wpts = WaypointService.instance.waypoints;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: const Color(0xFFB0B0B0),
        elevation: 0,
        title: const Text('Waypoints',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFFB0B0B0))),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_outlined),
            tooltip: 'Add waypoint manually',
            onPressed: () => _showEditSheet(context, null),
          ),
        ],
      ),
      body: wpts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No waypoints saved.\n\nTap the MOB button on the main screen to mark your current position, or use + to enter coordinates manually.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 15, height: 1.6),
                ),
              ),
            )
          : ListView.separated(
              itemCount: wpts.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Color(0xFF1A1A1A), height: 1),
              itemBuilder: (ctx, i) => _tile(ctx, wpts[i]),
            ),
    );
  }

  Widget _tile(BuildContext ctx, Waypoint wp) {
    final isActive = WaypointService.instance.activeId == wp.id;
    final pos = widget.currentPosition;
    final dist = pos != null
        ? formatDistanceUnit(haversineKm(pos.latitude, pos.longitude, wp.lat, wp.lon), widget.speedUnit)
        : null;

    return ListTile(
      tileColor: isActive ? const Color(0xFF1A0000) : Colors.transparent,
      leading: Icon(
        isActive ? Icons.navigation : Icons.location_on_outlined,
        color: isActive ? const Color(0xFFFF5252) : const Color(0xFF555555),
        size: 22,
      ),
      title: Text(
        wp.name,
        style: TextStyle(
          color: isActive ? const Color(0xFFFF5252) : Colors.white,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
          fontSize: 16,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _fmtTimestamp(wp.timestamp),
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          Text(
            '${formatLat(wp.lat)}  ${formatLon(wp.lon)}',
            style: const TextStyle(color: Colors.white24, fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
      trailing: dist != null
          ? Text(dist,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 14, fontWeight: FontWeight.w600))
          : null,
      onTap: () {
        HapticFeedback.lightImpact();
        if (isActive) {
          WaypointService.instance.deactivate();
        } else {
          WaypointService.instance.setActive(wp.id);
        }
        Navigator.pop(ctx, true);
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showEditSheet(ctx, wp);
      },
    );
  }

  void _showEditSheet(BuildContext ctx, Waypoint? existing) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final coordCtrl = TextEditingController(
      text: existing != null
          ? '${existing.lat.toStringAsFixed(6)}, ${existing.lon.toStringAsFixed(6)}'
          : '',
    );
    String? coordError;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (_, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, MediaQuery.of(sheetCtx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────────
              Text(
                existing != null ? 'Edit Waypoint' : 'Add Waypoint',
                style: const TextStyle(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              // ── Name ──────────────────────────────────────────────────────
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Name', 'e.g. Summit KR-001'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 16),
              // ── Coordinates ───────────────────────────────────────────────
              TextField(
                controller: coordCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration(
                  'Coordinates',
                  'lat, lon  (e.g. 52.1234, 18.5678)',
                  errorText: coordError,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                    signed: true, decimal: true),
              ),
              const SizedBox(height: 24),
              // ── Buttons ───────────────────────────────────────────────────
              Row(children: [
                if (existing != null)
                  TextButton(
                    onPressed: () => _confirmDelete(sheetCtx, existing),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF5252)),
                    child: const Text('Delete'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  style: TextButton.styleFrom(foregroundColor: Colors.white38),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A3A1A),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final parsed = _parseCoords(coordCtrl.text);
                    if (parsed == null) {
                      setSheetState(() => coordError = 'Invalid coordinates');
                      return;
                    }
                    Navigator.pop(sheetCtx);
                    if (existing != null) {
                      WaypointService.instance.rename(existing.id, nameCtrl.text);
                      WaypointService.instance.updateCoords(
                          existing.id, parsed.lat, parsed.lon);
                    } else {
                      WaypointService.instance.addManual(
                          nameCtrl.text, parsed.lat, parsed.lon);
                    }
                    setState(() {}); // refresh list
                  },
                  child: Text(existing != null ? 'Save' : 'Add'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext sheetCtx, Waypoint wp) {
    Navigator.pop(sheetCtx); // close edit sheet
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete waypoint?', style: TextStyle(color: Colors.white)),
        content: Text('Remove "${wp.name}"?',
            style: const TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              WaypointService.instance.remove(wp.id);
              Navigator.pop(dlgCtx);
              setState(() {});
            },
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF5252)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  static InputDecoration _inputDecoration(String label, String hint,
      {String? errorText}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: errorText,
      labelStyle: const TextStyle(color: Colors.white38),
      hintStyle: const TextStyle(color: Colors.white24),
      errorStyle: const TextStyle(color: Color(0xFFFF5252)),
      enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF333333))),
      focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF555555))),
      errorBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFFF5252))),
      focusedErrorBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFFF5252))),
    );
  }

  static ({double lat, double lon})? _parseCoords(String text) {
    final parts = text.split(',').map((s) => s.trim()).toList();
    if (parts.length < 2) return null;
    final lat = double.tryParse(parts[0]);
    final lon = double.tryParse(parts.sublist(1).join(',').trim());
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return (lat: lat, lon: lon);
  }

  static String _fmtTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    final days = diff.inDays;
    if (days < 7) return '${days}d ago';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final d = dt.toLocal();
    return '${d.day} ${months[d.month - 1]}  ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }
}
