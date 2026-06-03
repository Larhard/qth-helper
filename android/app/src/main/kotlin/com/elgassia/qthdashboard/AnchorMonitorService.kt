package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.content.SharedPreferences
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import kotlin.math.roundToInt

/**
 * Background foreground-service that monitors anchor position and fires the
 * alarm hardware even when the Flutter app is killed.
 *
 * Lifecycle:
 *   Start  — ACTION_START with lat/lon/radius/warnFrac extras
 *   Stop   — ACTION_STOP (or user lifts anchor)
 *
 * The service shows a persistent notification that returns the user to the app.
 * When the alarm level changes the notification is updated to reflect the state.
 *
 * Battery: the service is only started when the anchor is deployed.  It uses
 * LocationManager.GPS_PROVIDER with a 3 s interval and 0 m distance filter so
 * stationary updates are always delivered.
 */
class AnchorMonitorService : Service() {

    // ── Alarm levels (mirrors AnchorService.AnchorAlarmLevel in Dart) ────────
    private enum class Level { IDLE, WARNING, ALARM }

    companion object {
        const val ACTION_START = "com.elgassia.qthdashboard.ANCHOR_START"
        const val ACTION_STOP  = "com.elgassia.qthdashboard.ANCHOR_STOP"
        const val NOTIF_ID     = 2001
        const val CHANNEL_ID   = "anchor_monitor"
        const val PREFS_NAME   = "anchor_monitor_state"
    }

    // ── State ─────────────────────────────────────────────────────────────────
    private var anchorLat  = 0.0
    private var anchorLon  = 0.0
    private var radiusM    = 50.0
    private var warnFrac   = 0.80
    private var level      = Level.IDLE
    private var distanceM  = 0.0

    // ── Hardware ──────────────────────────────────────────────────────────────
    private val alarm by lazy { AnchorAlarmManager(this) }
    private var locManager: LocationManager? = null

    // ─────────────────────────────────────────────────────────────────────────
    // Service lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                anchorLat = intent.getDoubleExtra("lat",      0.0)
                anchorLon = intent.getDoubleExtra("lon",      0.0)
                radiusM   = intent.getDoubleExtra("radius",  50.0)
                warnFrac  = intent.getDoubleExtra("warnFrac", 0.80)
                saveState()
                startForeground(NOTIF_ID, buildNotification())
                startGps()
            }
            ACTION_STOP -> {
                clearState()
                alarm.stop()
                stopGps()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
            null -> {
                // START_STICKY restart by Android after process kill.
                // Restore state from SharedPreferences.
                val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                if (!prefs.getBoolean("active", false)) {
                    stopSelf(); return START_NOT_STICKY
                }
                anchorLat = prefs.getFloat("lat",      0f).toDouble()
                anchorLon = prefs.getFloat("lon",      0f).toDouble()
                radiusM   = prefs.getFloat("radius",  50f).toDouble()
                warnFrac  = prefs.getFloat("warnFrac", 0.80f).toDouble()
                startForeground(NOTIF_ID, buildNotification())
                startGps()
            }
        }
        return START_STICKY
    }

    private fun saveState() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putBoolean("active",   true)
            .putFloat("lat",        anchorLat.toFloat())
            .putFloat("lon",        anchorLon.toFloat())
            .putFloat("radius",     radiusM.toFloat())
            .putFloat("warnFrac",   warnFrac.toFloat())
            .apply()
    }

    private fun clearState() {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().clear().apply()
    }

    override fun onDestroy() {
        alarm.stop()
        stopGps()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ─────────────────────────────────────────────────────────────────────────
    // GPS monitoring
    // ─────────────────────────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun startGps() {
        locManager = getSystemService(LOCATION_SERVICE) as LocationManager
        try {
            locManager?.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                3_000L, // 3 s interval
                0f,     // no distance filter — stationary updates delivered
                locationListener,
            )
        } catch (_: Exception) {}
    }

    private fun stopGps() {
        try { locManager?.removeUpdates(locationListener) } catch (_: Exception) {}
        locManager = null
    }

    private val locationListener = LocationListener { location ->
        val dist = FloatArray(1)
        Location.distanceBetween(
            location.latitude, location.longitude,
            anchorLat, anchorLon,
            dist,
        )
        distanceM = dist[0].toDouble()
        updateAlarmLevel()
    }

    private fun updateAlarmLevel() {
        val newLevel = when {
            distanceM >= radiusM          -> Level.ALARM
            distanceM >= radiusM * warnFrac -> Level.WARNING
            else                          -> Level.IDLE
        }
        if (newLevel != level) {
            level = newLevel
            when (level) {
                Level.ALARM   -> alarm.startAlarm()
                Level.WARNING -> alarm.startWarning()
                Level.IDLE    -> alarm.stop()
            }
        }
        updateNotification()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Notification
    // ─────────────────────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Anchor Monitor",
                // IMPORTANCE_LOW: visible in notification shade, no sound/heads-up.
                // The alarm hardware is handled by AnchorAlarmManager, not by this
                // notification, so we deliberately suppress notification-level audio.
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Persistent anchor status — tap to return to QTH Dashboard"
                setSound(null, null)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification {
        val tapIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val (title, text) = when (level) {
            Level.ALARM   -> Pair("⚓ ANCHOR ALARM",     "Outside radius! ${distanceM.roundToInt()} m from anchor")
            Level.WARNING -> Pair("⚓ Anchor Warning",   "Approaching boundary — ${distanceM.roundToInt()} m of ${radiusM.roundToInt()} m")
            Level.IDLE    -> Pair("⚓ Anchor Active",    "Riding safely — ${distanceM.roundToInt()} m of ${radiusM.roundToInt()} m")
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(tapIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(tapIntent)
                .setOngoing(true)
                .build()
        }
    }

    private fun updateNotification() {
        try {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIF_ID, buildNotification())
        } catch (_: Exception) {}
    }
}
