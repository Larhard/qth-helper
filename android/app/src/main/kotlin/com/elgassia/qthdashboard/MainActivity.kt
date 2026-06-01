package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), SensorEventListener {

    // ── Pocket / proximity detection ──────────────────────────────────────────
    //
    // Logic: FLAG_KEEP_SCREEN_ON is active when ANY of these is true:
    //   • phone is charging                   (driving / sailing at powered helm)
    //   • phone is NOT near the proximity sensor  (held in hand, on dash, etc.)
    //   • Flutter "always-on" override is active  (broken-sensor fallback)
    //
    // Only when all three conditions are false (not charging, covered, no override)
    // does the flag get cleared — and only after a 5-second sustained delay, so
    // brief pocket bumps are ignored.
    //
    // The proximity sensor is registered only when pocket detection is meaningful
    // (not charging, override off), keeping it completely idle the rest of the time.

    private val sm by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }
    private var proxSensor: Sensor? = null
    private var proxRegistered = false
    private var isNearby = false           // current proximity state
    private var screenAlwaysOn = false     // Flutter override (disable pocket sleep)
    private val pocketHandler = Handler(Looper.getMainLooper())

    // Applied only after the phone has been continuously covered for 5 s.
    private val sleepRunnable = Runnable {
        if (isNearby && !isCharging() && !screenAlwaysOn) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // Register proximity sensor only when it can usefully prevent battery drain.
    private fun syncProximity() {
        val needed = !isCharging() && !screenAlwaysOn && proxSensor != null
        if (needed && !proxRegistered) {
            sm.registerListener(this, proxSensor!!, SensorManager.SENSOR_DELAY_NORMAL)
            proxRegistered = true
        } else if (!needed && proxRegistered) {
            sm.unregisterListener(this, proxSensor)
            proxRegistered = false
            pocketHandler.removeCallbacks(sleepRunnable)
            isNearby = false
        }
    }

    private fun isCharging(): Boolean {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
               status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun updateScreenKeepOn() {
        if (isCharging() || !isNearby || screenAlwaysOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // SensorEventListener — TYPE_PROXIMITY only.
    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_PROXIMITY) return
        val wasNearby = isNearby
        isNearby = event.values[0] < event.sensor.maximumRange
        pocketHandler.removeCallbacks(sleepRunnable)
        if (isNearby) {
            // Delay — avoids reacting to brief pocket contact or accidental covers.
            pocketHandler.postDelayed(sleepRunnable, 5_000L)
        } else if (wasNearby) {
            // Phone removed from pocket: restore keep-on immediately.
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Show over the lock screen without PIN / fingerprint.
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

        proxSensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY)

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        registerReceiver(chargingReceiver, filter)
        syncProximity()
        updateScreenKeepOn()
    }

    override fun onDestroy() {
        unregisterReceiver(chargingReceiver)
        if (proxRegistered) sm.unregisterListener(this, proxSensor)
        pocketHandler.removeCallbacks(sleepRunnable)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Screen always-on override ────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "setAlwaysOn") {
                    screenAlwaysOn = call.argument<Boolean>("value") ?: false
                    syncProximity()
                    updateScreenKeepOn()
                    result.success(null)
                } else result.notImplemented()
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

        // ── GNSS satellite status (API 24+, used only by the debug screen) ───
        // The EventChannel is idle when not subscribed — zero battery cost on
        // the main dashboard.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/gnss")
            .setStreamHandler(GnssStreamHandler(this))

        // ── Environmental / motion sensors (debug screen only) ───────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/environment")
            .setStreamHandler(SensorStreamHandler(this))
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
//
// Emits a Map<String, Any?> at 2 Hz while the stream is active.
// Automatically registers / unregisters SensorManager listeners so it costs
// nothing when the debug screen is closed.

private class SensorStreamHandler(private val activity: FlutterActivity) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sm = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    // Latest cached values (updated by onSensorChanged)
    private val latest = mutableMapOf<String, Double>()
    private var magX:  Double? = null; private var magY:  Double? = null; private var magZ:  Double? = null
    private var gravX: Double? = null; private var gravY: Double? = null; private var gravZ: Double? = null
    private var linX:  Double? = null; private var linY:  Double? = null; private var linZ:  Double? = null
    private var initialSteps: Double? = null

    // Which sensor keys are actually present on this device
    private val available = mutableSetOf<String>()

    // Sensor type → map key
    private val scalarSensors = mapOf(
        Sensor.TYPE_AMBIENT_TEMPERATURE to "temperature",  // °C  — rare
        Sensor.TYPE_PRESSURE            to "pressure",     // hPa — barometer
        Sensor.TYPE_LIGHT               to "light",        // lux
        Sensor.TYPE_RELATIVE_HUMIDITY   to "humidity",     // %RH — rare
        Sensor.TYPE_STEP_COUNTER        to "steps",        // cumulative, delta computed here
    )

    // 2 Hz emission loop
    private val emitRunnable = object : Runnable {
        override fun run() {
            emit()
            handler.postDelayed(this, 500L)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        available.clear()
        latest.clear()
        magX = null;  magY = null;  magZ = null
        gravX = null; gravY = null; gravZ = null
        linX = null;  linY = null;  linZ = null
        initialSteps = null

        // Register all scalar sensors that exist on this device
        for ((type, key) in scalarSensors) {
            sm.getDefaultSensor(type)?.also {
                sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
                available.add(key)
            }
        }

        // 3-axis sensors
        sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)?.also {
            sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
            available.add("magnetic")
        }
        sm.getDefaultSensor(Sensor.TYPE_GRAVITY)?.also {
            sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
            available.add("gravity")
        }
        sm.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)?.also {
            sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
            available.add("linear_accel")
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

        // Battery: level via BatteryManager, temperature via sticky broadcast
        val battIntent = try {
            activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (_: Exception) { null }
        val battLevel  = battIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val battScale  = battIntent?.getIntExtra(BatteryManager.EXTRA_SCALE,  -1) ?: -1
        val battPct    = if (battLevel >= 0 && battScale > 0) battLevel * 100.0 / battScale else null
        val battTempRaw = battIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        val battTempC  = if (battTempRaw != Int.MIN_VALUE) battTempRaw / 10.0 else null

        val data = HashMap<String, Any?>()
        data["available"]    = available.toList()
        data.putAll(latest)
        data["mag_x"]        = magX
        data["mag_y"]        = magY
        data["mag_z"]        = magZ
        data["grav_x"]       = gravX
        data["grav_y"]       = gravY
        data["grav_z"]       = gravZ
        data["lin_x"]        = linX
        data["lin_y"]        = linY
        data["lin_z"]        = linZ
        data["battery_pct"]  = battPct
        data["battery_temp"] = battTempC

        s.success(data)
    }
}
