import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/gpx_utils.dart';
import '../services/anchor_service.dart';
import '../services/overlay_service.dart';
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
  /// Called when the user confirms a new anchor drop or updates anchor settings.
  final void Function(double lat, double lon, double radiusM, double warnFrac)? onAnchorDrop;
  /// Called when the user taps "Lift anchor" in the setup sheet.
  final VoidCallback? onAnchorLift;

  const WaypointsScreen({
    super.key,
    required this.currentPosition,
    required this.speedUnit,
    required this.coordFormat,
    required this.locatorType,
    required this.timeUtc,
    required this.dayMode,
    this.onAnchorDrop,
    this.onAnchorLift,
  });

  @override
  State<WaypointsScreen> createState() => _WaypointsScreenState();
}

class _WaypointsScreenState extends State<WaypointsScreen> {
  Timer? _ticker;
  final Set<String> _selected = {};
  bool _selectModeActive = false;
  bool get _inSelectMode => _selectModeActive;

  bool get _day => widget.dayMode;
  Color get _cPrimary  => _day ? kDFg0 : kN1;
  Color get _cSecond   => _day ? kDFg2 : kN2;
  Color get _cTertiary => _day ? kDFg3 : kN3;
  Color get _cDim      => _day ? kDFg4 : kN3;
  Color get _cDistText => _day ? kDFg3 : kN3;
  Color _locColor(LocatorType t) => !_day
      ? kN2
      : t == LocatorType.maidenhead ? kDGps : kDAmb;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WaypointService.instance.clearImportHighlights();
    super.dispose();
  }

  // ── Snackbar helper (mirrors _HomeScreenState style) ─────────────────────
  void _snack(String msg, {Duration duration = const Duration(milliseconds: 2200)}) {
    final bg = _day ? kDSnackBg : kNBg;
    final fg = _day ? kDFg1     : kN2;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(color: fg, fontSize: 13), maxLines: 3),
      backgroundColor: bg,
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ));
  }

  // ── Floating overlay toggle ───────────────────────────────────────────────
  Future<void> _toggleOverlay() async {
    final oc = OverlayController.instance;
    if (oc.enabled) {
      oc.enabled = false;
      await oc.hide();
      setState(() {});
      _snack('Floating compass disabled.');
      return;
    }
    if (!await oc.hasPermission()) {
      await oc.requestPermission();
      _snack('Grant "Display over other apps", then tap the overlay button again.',
          duration: const Duration(seconds: 5));
      return;
    }
    oc.enabled = true;
    setState(() {});
    _snack('Floating compass enabled — it appears when you switch to another app.',
        duration: const Duration(seconds: 5));
  }

  // ── Multi-select delete ───────────────────────────────────────────────────
  void _deleteSelected() {
    final count = _selected.length;
    for (final id in List.of(_selected)) {
      WaypointService.instance.remove(id);
    }
    setState(() { _selected.clear(); _selectModeActive = false; });
    _snack('Deleted $count waypoint${count == 1 ? '' : 's'}.');
  }

  // ── GPX export ────────────────────────────────────────────────────────────
  Future<void> _exportGpx() async {
    final all   = WaypointService.instance.waypoints;
    final wpts  = (_inSelectMode && _selected.isNotEmpty)
        ? all.where((w) => _selected.contains(w.id)).toList()
        : all.toList();
    if (wpts.isEmpty) { _snack('No waypoints to export.'); return; }

    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/qth_waypoints.gpx');
    await file.writeAsString(GpxUtils.build(wpts));
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/gpx+xml')],
      subject: 'QTH Dashboard waypoints',
    );
  }

  static const _filePickerChannel = MethodChannel('qth_helper/file_picker');

  // ── GPX import (from in-app file picker) ─────────────────────────────────
  Future<void> _importGpx() async {
    final String? content;
    try {
      content = await _filePickerChannel.invokeMethod<String>('pickTextFile');
    } on PlatformException catch (e) {
      _snack('Could not read file: ${e.message}');
      return;
    }
    if (content == null) return; // user cancelled
    await _doImport(content);
  }

  // ── Shared import logic ───────────────────────────────────────────────────
  Future<void> _doImport(String content) async {
    List<GpxWaypoint> parsed;
    try {
      parsed = GpxUtils.parse(content);
    } catch (_) {
      _snack('The file is not valid GPX — could not import.');
      return;
    }
    if (parsed.isEmpty) {
      _snack('No waypoints found. Track points and route points are not imported.');
      return;
    }
    final r = WaypointService.instance.importWaypoints(parsed);
    setState(() {});
    _snackWithUndo(_importSummary(r, parsed.length), r.added);
  }

  void _snackWithUndo(String msg, int added) {
    final bg  = _day ? kDSnackBg : kNBg;
    final fg  = _day ? kDFg1     : kN2;
    final act = _day ? kDFg0     : kN0;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: TextStyle(color: fg, fontSize: 13), maxLines: 3),
        backgroundColor: bg,
        duration: const Duration(seconds: 8),
        action: added > 0 ? SnackBarAction(
          label: 'UNDO',
          textColor: act,
          onPressed: () {
            WaypointService.instance.undoLastImport();
            setState(() {});
          },
        ) : null,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ));
  }

  static String _importSummary(
      ({int added, int skipped, int renamed}) r, int total) {
    final parts = <String>[];
    if (r.added   > 0) parts.add('${r.added} added');
    if (r.renamed > 0) parts.add('${r.renamed} renamed (name conflict)');
    if (r.skipped > 0) parts.add('${r.skipped} already existed');
    if (parts.isEmpty) return 'No new waypoints — all already existed.';
    return 'Imported: ${parts.join(', ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final wpts = WaypointService.instance.waypoints;
    return PopScope(
      canPop: !_inSelectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _inSelectMode) setState(() {
          _selected.clear();
          _selectModeActive = false;
        });
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: _inSelectMode ? _selectionAppBar(wpts) : _normalAppBar(),
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
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              // Prevent the default grey Material elevation overlay during drag.
              proxyDecorator: (child, index, animation) => Material(
                color: Colors.black,
                elevation: 4,
                shadowColor: (_day ? kDDiv : kNDiv).withValues(alpha: 0.5),
                child: child,
              ),
              onReorderItem: (oldIndex, newIndex) {
                setState(() => WaypointService.instance.reorder(oldIndex, newIndex));
              },
              itemCount: wpts.length,
              itemBuilder: (ctx, i) => _tile(wpts[i], index: i, key: ValueKey(wpts[i].id)),
            ),
      ),   // Scaffold
    );   // WillPopScope
  }

  // ── Import badge ─────────────────────────────────────────────────────────
  Widget _importBadge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 1),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(label,
        style: TextStyle(
            color: color, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
  );

  // ── AppBar variants ───────────────────────────────────────────────────────
  AppBar _normalAppBar() => AppBar(
    backgroundColor: Colors.black,
    foregroundColor: _cTertiary,
    elevation: 0,
    title: Text('Waypoints',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _cTertiary)),
    actions: [
      IconButton(
        icon: const Icon(Icons.add_location_alt_outlined),
        tooltip: 'Add waypoint',
        onPressed: () => _showEditSheet(null),
      ),
      // Anchor alarm — long-press required to prevent accidental activation.
      GestureDetector(
        onLongPress: () {
          if (widget.currentPosition == null) {
            _snack('No GPS fix yet — cannot drop anchor without a position.');
            return;
          }
          _showAnchorSetupSheet();
        },
        onTap: () => _snack(
          AnchorService.instance.isActive
              ? 'Anchor is active. Long-press to change settings.'
              : 'Long-press the anchor icon to drop anchor.',
          duration: const Duration(milliseconds: 1800),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(
            Icons.anchor,
            color: AnchorService.instance.isActive
                ? (_day ? kDPort : kN1)
                : _cTertiary,
            size: 24,
          ),
        ),
      ),
      IconButton(
        icon: Icon(Icons.file_download_outlined, color: _cTertiary),
        tooltip: 'Import GPX',
        onPressed: _importGpx,
      ),
      IconButton(
        icon: Icon(Icons.file_upload_outlined, color: _cTertiary),
        tooltip: 'Export all GPX',
        onPressed: _exportGpx,
      ),
      IconButton(
        icon: Icon(
          OverlayController.instance.enabled
              ? Icons.picture_in_picture_alt
              : Icons.picture_in_picture_alt_outlined,
          color: OverlayController.instance.enabled
              ? (_day ? kDPort : kN1)
              : _cTertiary,
        ),
        tooltip: 'Floating compass overlay',
        onPressed: _toggleOverlay,
      ),
      IconButton(
        icon: Icon(Icons.checklist_outlined, color: _cTertiary),
        tooltip: 'Select waypoints',
        onPressed: () => setState(() => _selectModeActive = true),
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
  );

  AppBar _selectionAppBar(List<Waypoint> wpts) => AppBar(
    backgroundColor: Colors.black,
    elevation: 0,
    leading: IconButton(
      icon: Icon(Icons.close, color: _cTertiary),
      tooltip: 'Exit selection mode',
      onPressed: () => setState(() {
        _selected.clear();
        _selectModeActive = false;
      }),
    ),
    title: Text(
      _selected.isEmpty ? 'Select waypoints' : '${_selected.length} selected',
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _cTertiary),
    ),
    actions: [
      IconButton(
        icon: Icon(Icons.select_all, color: _cTertiary),
        tooltip: 'Select all',
        onPressed: () => setState(() {
          _selected.addAll(wpts.map((w) => w.id));
        }),
      ),
      IconButton(
        icon: Icon(Icons.file_upload_outlined, color: _cTertiary),
        tooltip: _selected.isEmpty ? 'Export all GPX' : 'Export selected GPX',
        onPressed: _exportGpx,
      ),
      if (_selected.isNotEmpty) IconButton(
        icon: Icon(Icons.delete_outline, color: _day ? kDStale : kN1),
        tooltip: 'Delete selected',
        onPressed: _deleteSelected,
      ),
    ],
  );

  Widget _tile(Waypoint wp, {required int index, Key? key}) {
    final isActive    = WaypointService.instance.activeId == wp.id;
    final isEmergency = WaypointService.instance.emergencyId == wp.id;
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

    final isSelected  = _selected.contains(wp.id);
    final isNew       = WaypointService.instance.newlyAddedIds.contains(wp.id);
    final isDupFound  = WaypointService.instance.dupFoundIds.contains(wp.id);
    final inkColor = (_day ? kDFg0 : kN2).withValues(alpha: 0.12);
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: isSelected ? (_day ? kDFg3.withValues(alpha: 0.12) : kN3.withValues(alpha: 0.18)) : null,
        border: Border(
          bottom: BorderSide(color: _day ? kDDiv : kNDiv, width: 1),
          left: isNew      ? BorderSide(color: _day ? kDGps  : kN0, width: 3)
               : isDupFound ? BorderSide(color: _day ? kDAmb  : kN2, width: 3)
               : BorderSide.none,
        ),
      ),
      child: Theme(
      data: Theme.of(context).copyWith(splashColor: inkColor, highlightColor: inkColor),
      child: ListTile(
      tileColor: (isEmergency || isActive) ? kNBg : Colors.transparent,
      leading: _inSelectMode
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => setState(() {
                isSelected ? _selected.remove(wp.id) : _selected.add(wp.id);
              }),
              side: BorderSide(color: _cDim),
              checkColor: Colors.black,
              fillColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected)
                      ? (_day ? kDFg0 : kN1)
                      : Colors.transparent),
            )
          : Icon(
              isEmergency
                  ? Icons.warning_rounded
                  : isActive ? Icons.navigation : Icons.location_on_outlined,
              color: isEmergency
                  ? kDEmg
                  : isActive ? (_day ? kDNav : kN0) : _cDim,
              size: 22,
            ),
      title: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Flexible(child: Text(
          wp.name,
          style: TextStyle(
            color: isEmergency
                ? kDEmg
                : isActive
                    ? (_day ? kDNav : kN0)
                    : _cPrimary,
            fontWeight: (isEmergency || isActive) ? FontWeight.w700 : FontWeight.w400,
            fontSize: 16,
          ),
        )),
        if (isNew)      ...[const SizedBox(width: 6), _importBadge('NEW',  _day ? kDGps : kN0)],
        if (isDupFound) ...[const SizedBox(width: 6), _importBadge('DUPE', _day ? kDAmb : kN2)],
      ]),
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
          Text(latStr,
              style: TextStyle(
                  color: _cSecond,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Text(lonStr,
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dist != null)
            Text(dist,
                style: TextStyle(
                    color: _cDistText,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          if (!_inSelectMode) ...[
            const SizedBox(width: 6),
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Icon(Icons.drag_handle, color: _cDim, size: 20),
              ),
            ),
          ],
        ],
      ),
      onTap: () {
        HapticFeedback.lightImpact();
        if (_inSelectMode) {
          setState(() {
            isSelected ? _selected.remove(wp.id) : _selected.add(wp.id);
          });
          return;
        }
        if (isActive) {
          WaypointService.instance.deactivate();
        } else {
          WaypointService.instance.setActive(wp.id);
        }
        Navigator.pop(context, true);
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        if (_inSelectMode) {
          setState(() {
            isSelected ? _selected.remove(wp.id) : _selected.add(wp.id);
          });
        } else {
          _showEditSheet(wp);
        }
      },
    ),   // ListTile
    ),   // Theme
    );   // DecoratedBox
  }

  // ── Anchor setup ─────────────────────────────────────────────────────────
  void _showAnchorSetupSheet() {
    final pos   = widget.currentPosition!;
    final svc   = AnchorService.instance;
    final isActive = svc.isActive;
    // Initialise sliders from existing or default values.
    double radius   = isActive ? svc.radiusM         : 50.0;
    double warnFrac = isActive ? svc.warningFraction  : 0.80;
    bool   testing  = false;

    const testCh = MethodChannel('qth_helper/anchor_alarm');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _day ? kDSheetBg : kNSheet,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => StatefulBuilder(
        builder: (_, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isActive ? 'Anchor settings' : 'Drop anchor',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                      color: _day ? kDFg0 : kN1)),
              const SizedBox(height: 4),
              Text(
                isActive
                    ? 'Drag will adjust alarm thresholds. GPS-on-lock stays active.'
                    : 'Anchor will be placed at your current GPS position.\n'
                      'GPS-on-lock is automatically enabled while anchored.',
                style: TextStyle(fontSize: 12, color: _day ? kDFg3 : kN3, height: 1.5),
              ),
              const SizedBox(height: 20),

              // ── Alarm radius ────────────────────────────────────────────
              Row(children: [
                Text('Alarm radius', style: TextStyle(fontSize: 13, color: _day ? kDFg2 : kN2)),
                const Spacer(),
                Text('${radius.round()} m',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                        color: _day ? kDFg0 : kN1)),
              ]),
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  activeTrackColor:     _day ? kDPort : kN1,
                  thumbColor:           _day ? kDPort : kN0,
                  inactiveTrackColor:   _day ? kDDiv  : kNDiv,
                  // Tick marks default to grey in dark themes — pin them to the
                  // palette so night mode stays pure black/red.
                  activeTickMarkColor:   _day ? kDPortL : kN0,
                  inactiveTickMarkColor: _day ? kDBrd   : kNDiv,
                  overlayColor: (_day ? kDPort : kN1).withValues(alpha: 0.18),
                  valueIndicatorColor: _day ? kDPort : kNBg,
                ),
                child: Slider(
                  value: radius.clamp(10.0, 1000.0),
                  min: 10, max: 1000,
                  divisions: 99,
                  onChanged: (v) => setS(() => radius = v),
                ),
              ),
              Row(children: [
                Text('10 m', style: TextStyle(fontSize: 10, color: _day ? kDFg4 : kN4)),
                const Spacer(),
                Text('1 000 m', style: TextStyle(fontSize: 10, color: _day ? kDFg4 : kN4)),
              ]),
              const SizedBox(height: 16),

              // ── Warning threshold ───────────────────────────────────────
              Row(children: [
                Text('Warning at', style: TextStyle(fontSize: 13, color: _day ? kDFg2 : kN2)),
                const Spacer(),
                Text('${(warnFrac * 100).round()} % of radius'
                    ' (${(radius * warnFrac).round()} m)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: _day ? kDStale : kN1)),
              ]),
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  activeTrackColor:     _day ? kDStale : kN2,
                  thumbColor:           _day ? kDStale : kN1,
                  inactiveTrackColor:   _day ? kDDiv   : kNDiv,
                  activeTickMarkColor:   _day ? kDAmbs : kN1,
                  inactiveTickMarkColor: _day ? kDBrd  : kNDiv,
                  overlayColor: (_day ? kDStale : kN1).withValues(alpha: 0.18),
                  valueIndicatorColor: _day ? kDStale : kNBg,
                ),
                child: Slider(
                  value: warnFrac.clamp(0.5, 0.95),
                  min: 0.5, max: 0.95,
                  divisions: 18,
                  onChanged: (v) => setS(() => warnFrac = v),
                ),
              ),
              Row(children: [
                Text('50 %', style: TextStyle(fontSize: 10, color: _day ? kDFg4 : kN4)),
                const Spacer(),
                Text('95 %', style: TextStyle(fontSize: 10, color: _day ? kDFg4 : kN4)),
              ]),
              const SizedBox(height: 16),

              // ── Test alarm ───────────────────────────────────────────────
              // Toggle: plays the alarm timbre at 20 % volume from all outputs
              // (speaker + headphones) so the crew can verify audibility.
              // Tap again to stop; auto-stops after 60 s.
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: testing ? (_day ? kDStale : kN1) : (_day ? kDFg3 : kN3),
                  side: BorderSide(
                      color: testing ? (_day ? kDStale : kN1) : (_day ? kDBrd : kNDiv)),
                ),
                icon: Icon(testing ? Icons.stop_circle_outlined : Icons.volume_up_outlined, size: 16),
                label: Text(testing ? 'Stop test' : 'Test alarm (quiet)'),
                onPressed: () async {
                  const ch = MethodChannel('qth_helper/anchor_alarm');
                  final nowTesting =
                      await ch.invokeMethod<bool>('testAlarm') ?? false;
                  setS(() => testing = nowTesting);
                  _snack(nowTesting
                      ? 'Testing alarm at 20 % volume — tap again to stop.'
                      : 'Test stopped.',
                      duration: const Duration(seconds: 3));
                },
              ),
              const SizedBox(height: 16),

              // ── Actions ─────────────────────────────────────────────────
              Row(children: [
                if (isActive) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _day ? kDStale : kN1,
                        side: BorderSide(color: _day ? kDStale : kN2),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onAnchorLift?.call();
                      },
                      child: const Text('Lift anchor'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _day ? kDPort : kNBg,
                      foregroundColor: _day ? Colors.black : kN1,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      widget.onAnchorDrop?.call(
                        pos.latitude, pos.longitude, radius, warnFrac);
                      _snack(isActive
                          ? 'Anchor settings updated.'
                          : 'Anchor dropped at current position.\n'
                            'GPS-on-lock has been enabled automatically.',
                        duration: const Duration(seconds: 4));
                    },
                    child: Text(isActive ? 'Update' : 'Drop anchor'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      // Always stop a running test when the sheet is dismissed.
      if (testing) testCh.invokeMethod('testAlarm').catchError((_) {});
    });
  }

  void _showEditSheet(Waypoint? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: widget.dayMode ? kDSheetBg : kNSheet,
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
  Color get _cText    => _day ? kDFg0   : kN1;
  Color get _cLabel   => _day ? kDFg3 : kN2;
  Color get _cHint    => _day ? kDFg4 : kN3;
  Color get _cBorder  => _day ? kDBrd   : kNDiv;
  Color get _cFocus   => _day ? kDFoc   : kN2;
  Color get _cSymBg   => _day ? const Color(0xFF1A2A1A) : kNBg; // green-tinted form bg
  Color get _cSymFg   => _day ? kDGps   : kN1;
  Color get _cSaveBg  => _day ? const Color(0xFF1A3A1A) : kNBg; // green-tinted save bg
  Color get _cCancel  => _day ? kDFg3 : kN2;
  Color get _cDlgBg   => _day ? kDDiv   : kNBg;
  Color get _cDlgBody => _day ? kDFg2 : kN2;

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
                foregroundColor: kDEmg),
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
                    foregroundColor: kDEmg),
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
      errorStyle: TextStyle(color: _day ? kDEmg : kN1),
      enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _cBorder)),
      focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _cFocus)),
      errorBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _day ? kDEmg : kN1)),
      focusedErrorBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: _day ? kDEmg : kN1)),
    );
  }
}
