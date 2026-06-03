package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import kotlin.math.roundToInt

/**
 * Foreground service that keeps the anchor alarm alive even when the Flutter
 * activity is killed.  It is the GPS feeder and notification owner; all level
 * logic and hardware live in [AnchorController] (the single authority).
 *
 * Battery: only ever started when an anchor is deployed.  Uses GPS_PROVIDER
 * (and NETWORK_PROVIDER as a redundant feed) at a 2 s / 0 m cadence so
 * stationary fixes are always delivered.  When the foreground app is alive it
 * ALSO forwards its (fused, more reliable) fixes into AnchorController, so the
 * GPS-loss timer is reset by whichever source delivers first.
 */
class AnchorMonitorService : Service() {

    companion object {
        const val ACTION_START = "com.elgassia.qthdashboard.ANCHOR_START"
        const val ACTION_STOP  = "com.elgassia.qthdashboard.ANCHOR_STOP"
        const val NOTIF_ID     = 2001
        const val CHANNEL_ID   = "anchor_monitor"
        const val PREFS_NAME   = "anchor_monitor_state"
    }

    private var locManager: LocationManager? = null
    private val handler = Handler(Looper.getMainLooper())

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        AnchorController.onStateChanged   = { updateNotification() }
        AnchorController.onAlarmEscalated = { launchActivity() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val lat = intent.getDoubleExtra("lat",      0.0)
                val lon = intent.getDoubleExtra("lon",      0.0)
                val r   = intent.getDoubleExtra("radius",  50.0)
                val wf  = intent.getDoubleExtra("warnFrac", 0.80)
                saveState(lat, lon, r, wf)
                AnchorController.start(this, lat, lon, r, wf)
                startForeground(NOTIF_ID, buildNotification())
                startGps()
                startTicker()
            }
            ACTION_STOP -> {
                clearState()
                AnchorController.stopAll()
                stopGps(); stopTicker()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
                    stopForeground(STOP_FOREGROUND_REMOVE)
                else @Suppress("DEPRECATION") stopForeground(true)
                stopSelf()
            }
            null -> {
                // START_STICKY restart after process kill — restore from prefs.
                val p = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                if (!p.getBoolean("active", false)) { stopSelf(); return START_NOT_STICKY }
                AnchorController.start(this,
                    p.getFloat("lat", 0f).toDouble(),
                    p.getFloat("lon", 0f).toDouble(),
                    p.getFloat("radius", 50f).toDouble(),
                    p.getFloat("warnFrac", 0.80f).toDouble())
                startForeground(NOTIF_ID, buildNotification())
                startGps(); startTicker()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopGps(); stopTicker()
        AnchorController.onStateChanged = null
        AnchorController.onAlarmEscalated = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── State persistence (for START_STICKY restart) ────────────────────────────

    private fun saveState(lat: Double, lon: Double, r: Double, wf: Double) {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putBoolean("active", true)
            .putFloat("lat", lat.toFloat()).putFloat("lon", lon.toFloat())
            .putFloat("radius", r.toFloat()).putFloat("warnFrac", wf.toFloat())
            .apply()
    }

    private fun clearState() =
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().clear().apply()

    // ── GPS ─────────────────────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun startGps() {
        locManager = getSystemService(LOCATION_SERVICE) as LocationManager
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            try {
                locManager?.requestLocationUpdates(provider, 2_000L, 0f, locationListener)
            } catch (_: Exception) {}
        }
    }

    private fun stopGps() {
        try { locManager?.removeUpdates(locationListener) } catch (_: Exception) {}
        locManager = null
    }

    private val locationListener = LocationListener { loc ->
        val acc = if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0
        AnchorController.onPosition(loc.latitude, loc.longitude, acc)
    }

    // ── 1 s ticker — drives the GPS-loss timer ─────────────────────────────────

    private val ticker = object : Runnable {
        override fun run() {
            AnchorController.tick()
            handler.postDelayed(this, 1_000L)
        }
    }
    private fun startTicker() { handler.removeCallbacks(ticker); handler.post(ticker) }
    private fun stopTicker()  { handler.removeCallbacks(ticker) }

    // ── Activity launch on alarm ────────────────────────────────────────────────

    private fun launchActivity() {
        try {
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                         Intent.FLAG_ACTIVITY_SINGLE_TOP or
                         Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            })
        } catch (_: Exception) {}
    }

    // ── Notification ──────────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Anchor Monitor",
                NotificationManager.IMPORTANCE_LOW).apply {
                description = "Persistent anchor status — tap to return to QTH Dashboard"
                setSound(null, null)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification {
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val dist = AnchorController.distanceM.roundToInt()
        val rad  = AnchorController.radiusM.roundToInt()
        val (title, text) = when (AnchorController.level) {
            2 -> "⚓ ANCHOR ALARM"   to (if (AnchorController.gpsLossSeconds >= 180)
                    "GPS lost ${AnchorController.gpsLossSeconds}s" else "Outside radius! $dist m from anchor")
            1 -> "⚓ Anchor Warning" to "Approaching boundary — $dist m of $rad m"
            else -> "⚓ Anchor Active" to "Riding — $dist m of $rad m"
        }

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentIntent(tap)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun updateNotification() {
        try {
            getSystemService(NotificationManager::class.java)?.notify(NOTIF_ID, buildNotification())
        } catch (_: Exception) {}
    }
}
