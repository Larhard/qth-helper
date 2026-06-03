import 'package:flutter/services.dart' show MethodChannel, Color;
import 'package:get_storage/get_storage.dart';

/// Controls the native floating compass overlay (`OverlayService`/`OverlayView`).
///
/// The overlay is rendered natively (no second Flutter engine) for low battery
/// and memory cost.  Colours are pushed as ARGB ints so the app's single colour
/// palette remains the source of truth.
///
/// UX: the overlay is shown only while the app is in the BACKGROUND (the home
/// screen calls [show]/[hide] from its lifecycle handler) — there's no point
/// drawing a compass on top of the full dashboard.  [enabled] is the persisted
/// user intent; [isShown] is whether the window is currently up.
class OverlayController {
  OverlayController._();
  static final instance = OverlayController._();

  static const _ch = MethodChannel('qth_helper/overlay');
  static final _store = GetStorage();
  static const _kEnabled = 'overlay_enabled';

  bool _shown = false;
  bool get isShown => _shown;

  bool get enabled => _store.read<bool>(_kEnabled) ?? false;
  set enabled(bool v) => _store.write(_kEnabled, v);

  Future<bool> hasPermission() async =>
      await _ch.invokeMethod<bool>('hasPermission') ?? false;

  Future<void> requestPermission() async {
    try { await _ch.invokeMethod('requestPermission'); } catch (_) {}
  }

  Future<void> show() async {
    try {
      _shown = await _ch.invokeMethod<bool>('show') ?? false;
    } catch (_) { _shown = false; }
  }

  Future<void> hide() async {
    try { await _ch.invokeMethod('hide'); } catch (_) {}
    _shown = false;
  }

  /// Push a fresh frame of data to the overlay (no-op if not shown).
  void update({
    required double heading,
    required bool headingValid,
    required bool windRose,
    double? secondaryBearing,
    required Color primaryColor,
    required Color secondaryColor,
    required Color northColor,
    required String line1,
    required String line2,
    required Color bgColor,
    required Color textColor,
    required Color subColor,
  }) {
    if (!_shown) return;
    _ch.invokeMethod('update', {
      'heading': heading,
      'headingValid': headingValid,
      'windRose': windRose,
      'secondaryBearing': secondaryBearing,
      'primaryColor': primaryColor.toARGB32(),
      'secondaryColor': secondaryColor.toARGB32(),
      'northColor': northColor.toARGB32(),
      'line1': line1,
      'line2': line2,
      'bgColor': bgColor.toARGB32(),
      'textColor': textColor.toARGB32(),
      'subColor': subColor.toARGB32(),
    }).catchError((_) {});
  }
}
