package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.GeomagneticField
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Magnetic declination ─────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/geomagnetic")
            .setMethodCallHandler { call, result ->
                if (call.method == "getDeclination") {
                    val lat = call.argument<Double>("lat") ?: 0.0
                    val lon = call.argument<Double>("lon") ?: 0.0
                    val alt = call.argument<Double>("alt") ?: 0.0
                    val field = GeomagneticField(
                        lat.toFloat(), lon.toFloat(), alt.toFloat(),
                        System.currentTimeMillis()
                    )
                    result.success(field.declination.toDouble())
                } else {
                    result.notImplemented()
                }
            }

        // ── GNSS satellite status (API 24+, used only by the debug screen) ───
        // The EventChannel is idle when not subscribed — zero battery cost on
        // the main dashboard.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/gnss")
            .setStreamHandler(GnssStreamHandler(this))
    }
}

// Streams GNSS constellation data to Flutter while the debug screen is open.
// Automatically unregisters the callback when Flutter cancels the subscription.
private class GnssStreamHandler(private val activity: FlutterActivity) :
    EventChannel.StreamHandler {

    private var gnssCallback: Any? = null // GnssStatus.Callback, held as Any for API-level safety

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            // Devices below API 24 cannot report GNSS status; send a single empty packet.
            events.success(mapOf("total" to 0, "used" to 0, "constellations" to emptyMap<String, Int>()))
            return
        }

        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val cb = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                val total = status.satelliteCount
                val used  = (0 until total).count { status.usedInFix(it) }
                val cons  = mutableMapOf<String, Int>()
                for (i in 0 until total) {
                    val name = when (status.getConstellationType(i)) {
                        GnssStatus.CONSTELLATION_GPS     -> "GPS"
                        GnssStatus.CONSTELLATION_GLONASS -> "GLO"
                        GnssStatus.CONSTELLATION_GALILEO -> "GAL"
                        GnssStatus.CONSTELLATION_BEIDOU  -> "BDS"
                        GnssStatus.CONSTELLATION_QZSS    -> "QZSS"
                        GnssStatus.CONSTELLATION_SBAS    -> "SBAS"
                        else                             -> "OTHER"
                    }
                    cons[name] = (cons[name] ?: 0) + 1
                }
                events.success(mapOf(
                    "total"          to total,
                    "used"           to used,
                    "constellations" to cons
                ))
            }
        }
        lm.registerGnssStatusCallback(cb, Handler(Looper.getMainLooper()))
        gnssCallback = cb
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val cb = gnssCallback as? GnssStatus.Callback
            if (cb != null) {
                (activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager)
                    .unregisterGnssStatusCallback(cb)
            }
        }
        gnssCallback = null
    }
}
