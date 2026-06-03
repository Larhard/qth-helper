package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraManager
import android.location.GnssStatus
import android.location.LocationManager
import android.net.Uri
import android.provider.Settings
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), SensorEventListener {

    // ── GPX file handling ─────────────────────────────────────────────────────
    // Two paths:
    //   1. User picks a file inside the app  (ACTION_OPEN_DOCUMENT → onActivityResult)
    //   2. User opens a .gpx file from another app  (ACTION_VIEW → readViewIntent)
    // In both cases the file content is read via ContentResolver and returned to
    // Dart as a UTF-8 string.

    private var filePickerResult: MethodChannel.Result? = null
    // Content from an ACTION_VIEW intent; consumed once by getPendingGpx().
    private var pendingGpxContent: String? = null

    private fun readViewIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW || intent.data == null) return
        try {
            pendingGpxContent = contentResolver.openInputStream(intent.data!!)
                ?.use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (_: Exception) {}
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readViewIntent(intent)
        // Notify the Dart side so it can poll immediately.
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, "qth_helper/file_picker")
                .invokeMethod("pendingGpxAvailable", null)
        }
    }

    @Deprecated("Still required for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_FILE) return
        val pending = filePickerResult ?: return
        filePickerResult = null
        if (resultCode == Activity.RESULT_OK && data?.data != null) {
            try {
                val bytes = contentResolver.openInputStream(data.data!!)?.use { it.readBytes() }
                pending.success(bytes?.toString(Charsets.UTF_8))
            } catch (e: Exception) {
                pending.error("READ_ERROR", e.message, null)
            }
        } else {
            pending.success(null)
        }
    }

    // ── Pocket-lock / proximity detection ─────────────────────────────────────
    //
    // When pocketLockEnabled is true and the phone is detected near a surface
    // (pocket) for 5 consecutive seconds:
    //   • screenBrightness = 0.0f  → window appears black instantly
    //   • FLAG_NOT_TOUCHABLE       → digitiser blocked (no accidental button presses)
    //   • FLAG_KEEP_SCREEN_ON cleared → backlight eventually off via system timeout
    //
    // We deliberately do NOT use DevicePolicyManager.lockNow(). Calling lockNow()
    // from a Device Admin triggers Android's "strong authentication required" policy,
    // which prevents fingerprint unlock and forces PIN entry — dangerous while driving.
    // The screenBrightness approach achieves the same practical result safely: the
    // screen is visually off and touch-blocked, but the keyguard remains in its normal
    // state so biometrics work immediately when the phone is taken out of the pocket.
    //
    // The proximity sensor is registered ONLY when pocket-lock is enabled and the
    // phone is not charging — zero sensor overhead otherwise.

    private val sm by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }

    private var proxSensor: Sensor? = null
    private var proxRegistered = false
    private var isNearby = false
    private var pocketLockEnabled = false
    private val pocketHandler = Handler(Looper.getMainLooper())

    // Fired after 5 s of sustained pocket contact.
    private val sleepRunnable = Runnable {
        if (!isNearby || !pocketLockEnabled || isCharging()) return@Runnable
        // Black out and block touch — no lockNow() to avoid forced-PIN behaviour.
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        setScreenBrightness(0.0f)
    }

    // Register proximity only when pocket-lock is on and useful (not charging).
    private fun syncProximity() {
        val needed = pocketLockEnabled && !isCharging() && proxSensor != null
        if (needed && !proxRegistered) {
            sm.registerListener(this, proxSensor!!, SensorManager.SENSOR_DELAY_NORMAL)
            proxRegistered = true
        } else if (!needed && proxRegistered) {
            sm.unregisterListener(this, proxSensor)
            proxRegistered = false
            pocketHandler.removeCallbacks(sleepRunnable)
            isNearby = false
            // Restore screen state when feature is turned off or charger connected.
            updateScreenKeepOn()
        }
    }

    private fun isCharging(): Boolean {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
               status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun updateScreenKeepOn() {
        // Screen stays on unless: pocket-lock on + phone covered + not charging.
        val keepOn = !pocketLockEnabled || !isNearby || isCharging()
        if (keepOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
            setScreenBrightness(WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE)
        }
        // clearFlags / addFlags for sleep are handled exclusively by sleepRunnable
        // after the 5-second delay to avoid abrupt mid-interaction changes.
    }

    private fun setScreenBrightness(value: Float) {
        val lp = window.attributes
        lp.screenBrightness = value
        window.attributes = lp
    }

    // SensorEventListener — TYPE_PROXIMITY only.
    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_PROXIMITY) return
        val wasNearby = isNearby
        isNearby = event.values[0] < event.sensor.maximumRange
        pocketHandler.removeCallbacks(sleepRunnable)
        if (isNearby) {
            pocketHandler.postDelayed(sleepRunnable, 5_000L)
        } else if (wasNearby) {
            updateScreenKeepOn()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

    // ── Charging broadcast ────────────────────────────────────────────────────
    private val chargingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            syncProximity()
            updateScreenKeepOn()
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

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

        readViewIntent(intent) // cold-start from ACTION_VIEW

        proxSensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY)

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        registerReceiver(chargingReceiver, filter)
        updateScreenKeepOn()
    }

    override fun onDestroy() {
        unregisterReceiver(chargingReceiver)
        if (proxRegistered) sm.unregisterListener(this, proxSensor)
        pocketHandler.removeCallbacks(sleepRunnable)
        super.onDestroy()
    }

    // ── Flutter channels ──────────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Pocket-lock / screen control ─────────────────────────────────────
        // No Device Admin involved — see class-level comment.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPocketLock" -> {
                        val enable = call.argument<Boolean>("enabled") ?: false
                        pocketLockEnabled = enable
                        if (!enable) {
                            pocketHandler.removeCallbacks(sleepRunnable)
                            isNearby = false
                        }
                        syncProximity()
                        updateScreenKeepOn()
                        result.success(mapOf("enabled" to pocketLockEnabled))
                    }
                    "getPocketLockStatus" -> result.success(mapOf("enabled" to pocketLockEnabled))
                    else -> result.notImplemented()
                }
            }

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

        // ── GNSS satellite status (debug screen only) ────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/gnss")
            .setStreamHandler(GnssStreamHandler(this))

        // ── Environmental / motion sensors (debug screen only) ───────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/environment")
            .setStreamHandler(SensorStreamHandler(this))

        // ── GPX file picker + intent receiver ────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/file_picker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> {
                        // Filter to GPX/XML MIME types — prevents .apk, images, etc.
                        // from cluttering the picker.  Content is still validated on
                        // the Dart side via XmlDocument.parse().
                        filePickerResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                    "application/gpx+xml",
                                    "application/xml",
                                    "text/xml",
                                    "text/plain",   // some managers assign this to .gpx
                                ))
                            },
                            REQUEST_PICK_FILE
                        )
                    }
                    "getPendingGpx" -> {
                        // Return content from an ACTION_VIEW intent (or null).
                        // Consumed once so repeated calls return null.
                        result.success(pendingGpxContent)
                        pendingGpxContent = null
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Anchor alarm ─────────────────────────────────────────────────────
        // Hardware + level logic live in AnchorController / AnchorMonitorService.
        // These channel methods are thin bridges only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/anchor_alarm")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "testAlarm" -> {
                        // Toggle: returns true if now testing, false if stopped.
                        val mgr = AnchorAlarmManager.getInstance(this)
                        mgr.toggleTest()
                        result.success(mgr.isTesting)
                    }
                    "startAnchorService" -> {
                        val lat  = call.argument<Double>("lat")  ?: 0.0
                        val lon  = call.argument<Double>("lon")  ?: 0.0
                        val r    = call.argument<Double>("radius")   ?: 50.0
                        val wf   = call.argument<Double>("warnFrac") ?: 0.80
                        val svc  = Intent(this, AnchorMonitorService::class.java).apply {
                            action = AnchorMonitorService.ACTION_START
                            putExtra("lat", lat); putExtra("lon", lon)
                            putExtra("radius", r); putExtra("warnFrac", wf)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                            startForegroundService(svc) else startService(svc)
                        result.success(null)
                    }
                    "stopAnchorService" -> {
                        startService(Intent(this, AnchorMonitorService::class.java).apply {
                            action = AnchorMonitorService.ACTION_STOP
                        })
                        result.success(null)
                    }
                    "getAnchorSnapshot"   -> result.success(AnchorController.snapshot())
                    "silenceAnchor"       -> { AnchorController.silence(); result.success(null) }
                    "escalateBattery"     -> {
                        AnchorController.escalateBattery(call.argument<Int>("floor") ?: 0)
                        result.success(null)
                    }
                    "forwardPosition"     -> {
                        // Foreground forwards its (reliable, fused) fixes so the
                        // GPS-loss timer is reset by the most reliable source.
                        AnchorController.onPosition(
                            call.argument<Double>("lat") ?: 0.0,
                            call.argument<Double>("lon") ?: 0.0)
                        result.success(null)
                    }
                    "getBatteryLevel" -> {
                        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                        val level  = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                        val scale  = intent?.getIntExtra(BatteryManager.EXTRA_SCALE,  -1) ?: -1
                        val pct    = if (level >= 0 && scale > 0) level * 100.0 / scale else -1.0
                        result.success(pct)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Floating overlay ─────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/overlay")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            Settings.canDrawOverlays(this))
                    "requestPermission" -> {
                        try {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")))
                        } catch (_: Exception) {}
                        result.success(null)
                    }
                    "isShown" -> result.success(OverlayService.isRunning)
                    "show" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            !Settings.canDrawOverlays(this)) {
                            result.success(false)
                        } else {
                            val i = Intent(this, OverlayService::class.java)
                                .apply { action = OverlayService.ACTION_SHOW }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                                startForegroundService(i) else startService(i)
                            result.success(true)
                        }
                    }
                    "hide" -> {
                        startService(Intent(this, OverlayService::class.java)
                            .apply { action = OverlayService.ACTION_HIDE })
                        result.success(null)
                    }
                    "update" -> {
                        OverlayService.instance?.update(
                            heading          = call.argument<Double>("heading") ?: 0.0,
                            headingValid     = call.argument<Boolean>("headingValid") ?: true,
                            windRose         = call.argument<Boolean>("windRose") ?: false,
                            secondaryBearing = call.argument<Double>("secondaryBearing"),
                            primaryColor     = (call.argument<Number>("primaryColor")   ?: 0).toLong(),
                            secondaryColor   = (call.argument<Number>("secondaryColor") ?: 0).toLong(),
                            northColor       = (call.argument<Number>("northColor")     ?: 0).toLong(),
                            line1            = call.argument<String>("line1") ?: "",
                            line2            = call.argument<String>("line2") ?: "",
                            bgColor          = (call.argument<Number>("bgColor")   ?: 0).toLong(),
                            textColor        = (call.argument<Number>("textColor") ?: 0).toLong(),
                            subColor         = (call.argument<Number>("subColor")  ?: 0).toLong(),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val REQUEST_PICK_FILE = 1001
    }
}

// ── GNSS stream ───────────────────────────────────────────────────────────────

private class GnssStreamHandler(private val activity: FlutterActivity) :
    EventChannel.StreamHandler {

    private var gnssCallback: Any? = null

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
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

// ── Environmental / motion sensor stream ──────────────────────────────────────

private class SensorStreamHandler(private val activity: FlutterActivity) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sm = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    private val latest = mutableMapOf<String, Double>()
    private var magX:  Double? = null; private var magY:  Double? = null; private var magZ:  Double? = null
    private var gravX: Double? = null; private var gravY: Double? = null; private var gravZ: Double? = null
    private var linX:  Double? = null; private var linY:  Double? = null; private var linZ:  Double? = null
    private var initialSteps: Double? = null

    private val available = mutableSetOf<String>()

    private val scalarSensors = mapOf(
        Sensor.TYPE_AMBIENT_TEMPERATURE to "temperature",
        Sensor.TYPE_PRESSURE            to "pressure",
        Sensor.TYPE_LIGHT               to "light",
        Sensor.TYPE_RELATIVE_HUMIDITY   to "humidity",
        Sensor.TYPE_STEP_COUNTER        to "steps",
        Sensor.TYPE_PROXIMITY           to "proximity",
    )

    private val emitRunnable = object : Runnable {
        override fun run() {
            emit()
            handler.postDelayed(this, 500L)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        available.clear(); latest.clear()
        magX = null;  magY = null;  magZ = null
        gravX = null; gravY = null; gravZ = null
        linX = null;  linY = null;  linZ = null
        initialSteps = null

        for ((type, key) in scalarSensors) {
            sm.getDefaultSensor(type)?.also {
                sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
                available.add(key)
            }
        }
        listOf(
            Sensor.TYPE_MAGNETIC_FIELD     to "magnetic",
            Sensor.TYPE_GRAVITY            to "gravity",
            Sensor.TYPE_LINEAR_ACCELERATION to "linear_accel",
        ).forEach { (type, key) ->
            sm.getDefaultSensor(type)?.also {
                sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
                available.add(key)
            }
        }

        handler.post(emitRunnable)
    }

    override fun onCancel(arguments: Any?) {
        handler.removeCallbacks(emitRunnable)
        sm.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_STEP_COUNTER -> {
                val raw = event.values[0].toDouble()
                if (initialSteps == null) initialSteps = raw
                latest["steps"] = raw - (initialSteps ?: raw)
            }
            Sensor.TYPE_MAGNETIC_FIELD -> {
                magX = event.values[0].toDouble()
                magY = event.values[1].toDouble()
                magZ = event.values[2].toDouble()
            }
            Sensor.TYPE_GRAVITY -> {
                gravX = event.values[0].toDouble()
                gravY = event.values[1].toDouble()
                gravZ = event.values[2].toDouble()
            }
            Sensor.TYPE_LINEAR_ACCELERATION -> {
                linX = event.values[0].toDouble()
                linY = event.values[1].toDouble()
                linZ = event.values[2].toDouble()
            }
            else -> {
                val key = scalarSensors[event.sensor.type] ?: return
                latest[key] = event.values[0].toDouble()
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

    private fun emit() {
        val s = sink ?: return

        val battIntent = try {
            activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (_: Exception) { null }
        val battLevel  = battIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val battScale  = battIntent?.getIntExtra(BatteryManager.EXTRA_SCALE,  -1) ?: -1
        val battPct    = if (battLevel >= 0 && battScale > 0) battLevel * 100.0 / battScale else null
        val battTempRaw = battIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        val battTempC  = if (battTempRaw != Int.MIN_VALUE) battTempRaw / 10.0 else null

        // Proximity max range needed to determine NEAR/FAR on the Dart side.
        val proxMaxRange = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY)?.maximumRange?.toDouble()

        val data = HashMap<String, Any?>()
        data["available"]        = available.toList()
        data.putAll(latest)
        data["mag_x"]            = magX;   data["mag_y"]  = magY;   data["mag_z"]  = magZ
        data["grav_x"]           = gravX;  data["grav_y"] = gravY;  data["grav_z"] = gravZ
        data["lin_x"]            = linX;   data["lin_y"]  = linY;   data["lin_z"]  = linZ
        data["battery_pct"]      = battPct
        data["battery_temp"]     = battTempC
        data["proximity_max"]    = proxMaxRange

        s.success(data)
    }
}
