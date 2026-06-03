package com.elgassia.qthdashboard

import android.content.Context
import android.location.Location
import android.os.SystemClock

/**
 * Single source of truth for anchor-alarm STATE and LEVEL logic.
 *
 * Owned by no single component: both [AnchorMonitorService] (which feeds GPS and
 * owns the notification) and [MainActivity] (which bridges to Flutter) delegate
 * here.  This guarantees there is exactly one level computation and one
 * [AnchorAlarmManager] driving the hardware — eliminating the dual-instance
 * audio fight.
 *
 * Level thresholds MUST stay in sync with the Dart spec in
 * `lib/utils/anchor_math.dart` (see AnchorMath).  The Dart copy exists so the
 * logic is unit-tested; this copy exists so the service is self-sufficient when
 * the Flutter engine is dead.
 *
 *   level 0 idle    — inside warn zone, GPS fresh
 *   level 1 warning — dist ≥ warnFrac·radius, OR GPS lost 60–180 s, OR battery floor 1
 *   level 2 alarm   — dist ≥ radius,         OR GPS lost > 180 s,    OR battery floor 2
 */
object AnchorController {

    // ── Configuration ────────────────────────────────────────────────────────
    @Volatile var active = false;     private set
    @Volatile var lat = 0.0;          private set
    @Volatile var lon = 0.0;          private set
    @Volatile var radiusM = 50.0;     private set
    @Volatile var warnFrac = 0.80;    private set

    // ── Live state ────────────────────────────────────────────────────────────
    @Volatile var distanceM = 0.0;       private set
    @Volatile var bearingDeg = 0.0;      private set
    @Volatile var gpsLossSeconds = 0;    private set
    @Volatile var level = 0;             private set   // 0 idle, 1 warning, 2 alarm
    @Volatile var silenced = false;      private set
    @Volatile var hasFix = false;        private set

    private var batteryFloor = 0
    private var lastFixElapsed = 0L      // SystemClock.elapsedRealtime of last fix
    private var alarm: AnchorAlarmManager? = null

    /** Service sets this to refresh its notification when state changes. */
    var onStateChanged: (() -> Unit)? = null
    /** Service sets this to launch the activity when escalating to ALARM. */
    var onAlarmEscalated: (() -> Unit)? = null

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    fun start(ctx: Context, lat: Double, lon: Double, radiusM: Double, warnFrac: Double) {
        alarm = AnchorAlarmManager.getInstance(ctx)
        this.lat = lat; this.lon = lon
        this.radiusM = radiusM; this.warnFrac = warnFrac
        active = true
        distanceM = 0.0; bearingDeg = 0.0
        gpsLossSeconds = 0; level = 0; silenced = false
        batteryFloor = 0; hasFix = false
        lastFixElapsed = SystemClock.elapsedRealtime()
        onStateChanged?.invoke()
    }

    fun stopAll() {
        active = false
        level = 0; silenced = false; batteryFloor = 0
        gpsLossSeconds = 0; hasFix = false
        alarm?.stop()
        onStateChanged?.invoke()
    }

    // ── Inputs ──────────────────────────────────────────────────────────────────

    /** A fresh GPS fix (from the service's GPS or forwarded from the foreground). */
    fun onPosition(lat: Double, lon: Double) {
        if (!active) return
        val d = FloatArray(2)
        Location.distanceBetween(lat, lon, this.lat, this.lon, d)
        distanceM = d[0].toDouble()
        bearingDeg = ((d[1] + 360.0) % 360.0)
        hasFix = true
        lastFixElapsed = SystemClock.elapsedRealtime()
        gpsLossSeconds = 0
        recompute()
    }

    /** Periodic tick (every 1 s) — recomputes GPS-loss duration from the clock. */
    fun tick() {
        if (!active) return
        gpsLossSeconds = ((SystemClock.elapsedRealtime() - lastFixElapsed) / 1000L).toInt()
        recompute()
    }

    fun silence() {
        silenced = true
        alarm?.stop()
        onStateChanged?.invoke()
    }

    /** Battery escalation from the foreground: floor = 1 (warning) or 2 (alarm). */
    fun escalateBattery(floor: Int) {
        if (!active) return
        if (floor > batteryFloor) batteryFloor = floor
        recompute()
    }

    // ── Snapshot for the Flutter side ────────────────────────────────────────────

    fun snapshot(): Map<String, Any> = mapOf(
        "active"         to active,
        "level"          to level,
        "distanceM"      to distanceM,
        "bearingDeg"     to bearingDeg,
        "gpsLossSeconds" to gpsLossSeconds,
        "silenced"       to silenced,
        "hasFix"         to hasFix,
        "radiusM"        to radiusM,
        "warnFrac"       to warnFrac,
    )

    // ── Core logic ────────────────────────────────────────────────────────────────

    private fun recompute() {
        val positionLevel = when {
            !hasFix                          -> 0   // no fix yet → rely on GPS-loss timer
            distanceM >= radiusM             -> 2
            distanceM >= radiusM * warnFrac  -> 1
            else                             -> 0
        }
        val gpsLossLevel = when {
            gpsLossSeconds >= 180 -> 2
            gpsLossSeconds >= 60  -> 1
            else                  -> 0
        }
        val newLevel = maxOf(positionLevel, gpsLossLevel, batteryFloor)

        // Escalation un-silences so the louder level can sound.
        if (newLevel > level) silenced = false
        // Returning to safety re-arms the silence for next time.
        if (newLevel == 0) silenced = false

        val changed = newLevel != level
        level = newLevel

        if (!silenced) applyHardware()
        if (changed && newLevel == 2) onAlarmEscalated?.invoke()
        if (changed) onStateChanged?.invoke()
    }

    private fun applyHardware() {
        when (level) {
            2 -> alarm?.startAlarm()
            1 -> alarm?.startWarning()
            else -> alarm?.stop()
        }
    }
}
