import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'about_screen.dart';
import '../models/waypoint.dart';
import '../services/waypoint_service.dart';
import '../utils/coordinate_utils.dart' show formatLatF, formatLonF, maidenhead, parseCoordValue, coordLatHint, coordLonHint;
import '../utils/geo_utils.dart';
import '../utils/mgrs_utils.dart';
import '../utils/units.dart';

class WaypointsScreen extends StatefulWidget {
  final Position? currentPosition;
  final SpeedUnit speedUnit;
  final CoordFormat coordFormat;
  final LocatorType locatorType;
  final bool timeUtc;
  final bool dayMode;

  const WaypointsScreen({
    super.key,
    required this.currentPosition,
    required this.speedUnit,
    required this.coordFormat,
    required this.locatorType,
    required this.timeUtc,
    required this.dayMode,
  });

  @override
  State<WaypointsScreen> createState() => _WaypointsScreenState();
}

class _WaypointsScreenState extends State<WaypointsScreen> {
  Timer? _ticker;

  bool get _day => widget.dayMode;
  Color get _cPrimary  => _day ? Colors.white               : const Color(0xFFCC3333);
  Color get _cSecond   => _day ? const Color(0xFFCCCCCC)    : const Color(0xFF882222);
  Color get _cTertiary => _day ? const Color(0xFF888888)    : const Color(0xFF551111);
  Color get _cDim      => _day ? const Color(0xFF666666)    : const Color(0xFF441111);
  Color get _cActive   => _day ? const Color(0xFFFF3333)    : const Color(0xFF882222);
  Color get _cDistText => _day ? const Color(0xFFAAAAAA)    : const Color(0xFF661111);
  Color _locColor(LocatorType t) => !_day
      ? const Color(0xFF882222)
      : t == LocatorType.maidenhead
          ? const Color(0xFF55DD55)
          : const Color(0xFFFFA726);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wpts = WaypointService.instance.waypoints;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: _cTertiary,
        elevation: 0,
        title: Text('Waypoints',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _cTertiary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_outlined),
            tooltip: 'Add waypoint manually',
            onPressed: () => _showEditSheet(null),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About & Legal',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AboutScreen(dayMode: widget.dayMode)),
            ),
          ),
        ],
      ),
      body: wpts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No waypoints saved.\n\nTap MOB on the main screen to mark your current position, or use + to enter coordinates manually.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _cDim, fontSize: 15, height: 1.6),
                ),
              ),
            )
          : ListView.separated(
              itemCount: wpts.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Color(0xFF1A1A1A), height: 1),
              itemBuilder: (ctx, i) => _tile(wpts[i]),
            ),
    );
  }

  Widget _tile(Waypoint wp) {
    final isActive = WaypointService.instance.activeId == wp.id;
    final pos = widget.currentPosition;
    final dist = pos != null
        ? formatDistanceUnit(
            haversineKm(pos.latitude, pos.longitude, wp.lat, wp.lon),
            widget.speedUnit)
        : null;

    final latStr = formatLatF(wp.lat, widget.coordFormat);
    final lonStr = formatLonF(wp.lon, widget.coordFormat);
    final locStr = widget.locatorType == LocatorType.maidenhead
        ? maidenhead(wp.lat, wp.lon)
        : mgrs(wp.lat, wp.lon);
    final locLabel = widget.locatorType == LocatorType.maidenhead ? 'IARU' : 'MGRS';
    final locColor = _locColor(widget.locatorType);

    return ListTile(
      tileColor: isActive ? const Color(0xFF1A0000) : Colors.transparent,
      leading: Icon(
        isActive ? Icons.navigation : Icons.location_on_outlined,
        color: isActive ? _cActive : _cDim,
        size: 22,
      ),
      title: Text(
        wp.name,
        style: TextStyle(
          color: isActive ? _cActive : _cPrimary,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
          fontSize: 16,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(_fmtTimestamp(wp.timestamp, widget.timeUtc),
                style: TextStyle(color: _cDim, fontSize: 11)),
            const SizedBox(width: 8),
            Text(
              formatElapsed(DateTime.now().difference(wp.timestamp)),
              style: TextStyle(
                  color: _cTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ]),
          const SizedBox(height: 2),
          Text('$latStr   $lonStr',
              style: TextStyle(
                  color: _cSecond,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Row(children: [
            Text(locStr,
                style: TextStyle(
                    color: locColor,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 4),
            Text(locLabel,
                style: TextStyle(
                    color: _cDim,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
          ]),
        ],
      ),
      isThreeLine: true,
      trailing: dist != null
          ? Text(dist,
              style: TextStyle(
                  color: _cDistText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600))
          : null,
      onTap: () {
        HapticFeedback.lightImpact();
        if (isActive) {
          WaypointService.instance.deactivate();
        } else {
          WaypointService.instance.setActive(wp.id);
        }
        Navigator.pop(context, true);
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showEditSheet(wp);
      },
    );
  }

  void _showEditSheet(Waypoint? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: widget.dayMode
          ? const Color(0xFF111111)
          : const Color(0xFF0A0000),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => _WptEditSheet(
        existing: existing,
        screenCtx: context,
        coordFormat: widget.coordFormat,
        dayMode: widget.dayMode,
        onSaved: () => setState(() {}),
      ),
    );
  }

  static String _fmtTimestamp(DateTime dt, bool utc) {
    final d = utc ? dt.toUtc() : dt.toLocal();
    final zone = utc ? 'UTC' : 'LCL';
    return '${d.year}-'
        '${d.month.toString().padLeft(2,'0')}-'
        '${d.day.toString().padLeft(2,'0')} '
        '${d.hour.toString().padLeft(2,'0')}:'
        '${d.minute.toString().padLeft(2,'0')}:'
        '${d.second.toString().padLeft(2,'0')} $zone';
  }
}

// ── Edit / add bottom sheet ────────────────────────────────────────────────────

class _WptEditSheet extends StatefulWidget {
  final Waypoint? existing;
  final BuildContext screenCtx;
  final CoordFormat coordFormat;
  final bool dayMode;
  final VoidCallback onSaved;

  const _WptEditSheet({
    required this.existing,
    required this.screenCtx,
    required this.coordFormat,
    required this.dayMode,
    required this.onSaved,
  });

  @override
  State<_WptEditSheet> createState() => _WptEditSheetState();
}

class _WptEditSheetState extends State<_WptEditSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _latCtrl;
  late final TextEditingController _lonCtrl;
  late final FocusNode _latFocus;
  late final FocusNode _lonFocus;
  bool _latFocused = true;
  String? _latError;
  String? _lonError;

  @override
  void initState() {
    super.initState();
    final wp = widget.existing;
    _nameCtrl = TextEditingController(text: wp?.name ?? '');
    _latCtrl = TextEditingController(
        text: wp != null ? formatLatF(wp.lat, widget.coordFormat) : '');
    _lonCtrl = TextEditingController(
        text: wp != null ? formatLonF(wp.lon, widget.coordFormat) : '');

    _latFocus = FocusNode()
      ..addListener(() {
        if (_latFocus.hasFocus) setState(() => _latFocused = true);
      });
    _lonFocus = FocusNode()
      ..addListener(() {
        if (_lonFocus.hasFocus) setState(() => _latFocused = false);
      });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _latCtrl.dispose();
    _lonCtrl.dispose();
    _latFocus.dispose();
    _lonFocus.dispose();
    super.dispose();
  }

  void _insertSym(String sym) {
    final ctrl = _latFocused ? _latCtrl : _lonCtrl;
    final focus = _latFocused ? _latFocus : _lonFocus;
    final sel = ctrl.selection;
    final pos = sel.isValid ? sel.extentOffset.clamp(0, ctrl.text.length) : ctrl.text.length;
    final text = ctrl.text;
    ctrl.value = TextEditingValue(
      text: text.substring(0, pos) + sym + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + sym.length),
    );
    focus.requestFocus();
  }

  void _save() {
    final lat = parseCoordValue(_latCtrl.text);
    final lon = parseCoordValue(_lonCtrl.text);
    final latOk = lat != null && lat >= -90 && lat <= 90;
    final lonOk = lon != null && lon >= -180 && lon <= 180;
    if (!latOk || !lonOk) {
      setState(() {
        _latError = latOk ? null : 'Invalid latitude';
        _lonError = lonOk ? null : 'Invalid longitude';
      });
      return;
    }
    Navigator.pop(context);
    final wp = widget.existing;
    if (wp != null) {
      WaypointService.instance.rename(wp.id, _nameCtrl.text);
      WaypointService.instance.updateCoords(wp.id, lat, lon);
    } else {
      WaypointService.instance.addManual(_nameCtrl.text, lat, lon);
    }
    widget.onSaved();
  }

  // ── Night-safe colour helpers ─────────────────────────────────────────────
  bool get _day => widget.dayMode;
  Color get _cText    => _day ? Colors.white               : const Color(0xFFCC3333);
  Color get _cLabel   => _day ? Colors.white38             : const Color(0xFF882222);
  Color get _cHint    => _day ? Colors.white24             : const Color(0xFF551111);
  Color get _cBorder  => _day ? const Color(0xFF333333)    : const Color(0xFF440000);
  Color get _cFocus   => _day ? const Color(0xFF555555)    : const Color(0xFF882222);
  Color get _cSymBg   => _day ? const Color(0xFF1A2A1A)    : const Color(0xFF1A0000);
  Color get _cSymFg   => _day ? const Color(0xFF55DD55)    : const Color(0xFFCC3333);
  Color get _cSaveBg  => _day ? const Color(0xFF1A3A1A)    : const Color(0xFF3A0000);
  Color get _cCancel  => _day ? Colors.white38             : const Color(0xFF882222);
  Color get _cDlgBg   => _day ? const Color(0xFF1A1A1A)    : const Color(0xFF1A0000);
  Color get _cDlgBody => _day ? Colors.white54             : const Color(0xFF882222);

  void _confirmDelete() {
    Navigator.pop(context);
    showDialog(
      context: widget.screenCtx,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: _cDlgBg,
        title: Text('Delete waypoint?', style: TextStyle(color: _cText)),
        content: Text('Remove "${widget.existing!.name}"?',
            style: TextStyle(color: _cDlgBody)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: Text('Cancel', style: TextStyle(color: _cCancel)),
          ),
          TextButton(
            onPressed: () {
              WaypointService.instance.remove(widget.existing!.id);
              Navigator.pop(dlgCtx);
              widget.onSaved();
            },
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFF3333)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final latHint = coordLatHint(widget.coordFormat);
    final lonHint = coordLonHint(widget.coordFormat);
    final needsSymbols = widget.coordFormat != CoordFormat.degDec;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Text(widget.existing != null ? 'Edit Waypoint' : 'Add Waypoint',
              style: TextStyle(
                  color: _cText, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),

          // ── Name ────────────────────────────────────────────────────────
          TextField(
            controller: _nameCtrl,
            style: TextStyle(color: _cText),
            decoration: _dec('Name', 'e.g. Summit KR-001'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),

          // ── Latitude ─────────────────────────────────────────────────────
          TextField(
            controller: _latCtrl,
            focusNode: _latFocus,
            style: TextStyle(color: _cText),
            decoration: _dec('Latitude', latHint, errorText: _latError),
            keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true),
          ),
          const SizedBox(height: 12),

          // ── Longitude ────────────────────────────────────────────────────
          TextField(
            controller: _lonCtrl,
            focusNode: _lonFocus,
            style: TextStyle(color: _cText),
            decoration: _dec('Longitude', lonHint, errorText: _lonError),
            keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true),
          ),

          // ── Symbol buttons (DDM / DMS only) ──────────────────────────────
          if (needsSymbols) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: ["°", "'", "\"", 'N', 'S', 'E', 'W']
                  .map((s) => TextButton(
                        onPressed: () => _insertSym(s),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          backgroundColor: _cSymBg,
                          foregroundColor: _cSymFg,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4)),
                        ),
                        child: Text(s,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ))
                  .toList(),
            ),
          ],

          const SizedBox(height: 20),

          // ── Action row ───────────────────────────────────────────────────
          Row(children: [
            if (widget.existing != null)
              TextButton(
                onPressed: _confirmDelete,
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF3333)),
                child: const Text('Delete'),
              ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: _cCancel),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _cSaveBg,
                foregroundColor: _cText,
              ),
              onPressed: _save,
              child: Text(widget.existing != null ? 'Save' : 'Add'),
            ),
          ]),
        ],
      ),
    );
  }

  InputDecoration _dec(String label, String hint, {String? errorText}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: errorText,
      labelStyle: TextStyle(color: _cLabel),
      hintStyle: TextStyle(color: _cHint),
      errorStyle: const TextStyle(color: Color(0xFFFF3333)),
      enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _cBorder)),
      focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _cFocus)),
      errorBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFFF3333))),
      focusedErrorBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFFF3333))),
    );
  }
}
