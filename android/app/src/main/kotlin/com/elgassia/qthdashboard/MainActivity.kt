package com.elgassia.qthdashboard

import android.annotation.SuppressLint
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
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

    // ── Pocket-lock / proximity detection ─────────────────────────────────────
    //
    // When pocketLockEnabled is true and the phone is detected near a surface
    // (pocket) for 5 consecutive seconds, the screen is locked:
    //   • Device Admin active  → DevicePolicyManager.lockNow()  (true screen lock)
    //   • Device Admin absent  → screenBrightness = 0.0f        (visual black + timeout)
    //
    // The proximity sensor is registered ONLY when pocket-lock is enabled and
    // the phone is not charging — zero sensor overhead otherwise.
    //
    // Default: feature is disabled.  User enables via the SCR toggle in the UI,
    // which triggers the Device Admin activation prompt if not yet granted.

    private val sm by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }
    private val dpm by lazy { getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager }
    private val adminComp by lazy { ComponentName(this, LockReceiver::class.java) }

    private var proxSensor: Sensor? = null
    private var proxRegistered = false
    private var isNearby = false           // current proximity reading
    private var pocketLockEnabled = false  // persisted via Flutter / GetStorage
    private var pendingEnable = false      // set while waiting for admin grant
    private val pocketHandler = Handler(Looper.getMainLooper())

    // Fired after 5 s of sustained pocket contact.
    private val sleepRunnable = Runnable {
        if (!isNearby || !pocketLockEnabled || isCharging()) return@Runnable
        if (isAdminActive()) {
            dpm.lockNow()   // true screen lock — keyguard blocks all touch input
        } else {
            // Fallback: black out the window visually.
            // FLAG_NOT_TOUCHABLE disables the digitizer for this window so pocket
            // fabric cannot trigger any buttons behind the black screen.
            // The flag is cleared in updateScreenKeepOn() when the phone is removed
            // from the pocket.
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
            setScreenBrightness(0.0f)
        }
    }

    private fun isAdminActive() = dpm.isAdminActive(adminComp)

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

        proxSensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY)

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        registerReceiver(chargingReceiver, filter)
        updateScreenKeepOn()
    }

    // Called when the user returns from the Device Admin activation screen.
    override fun onResume() {
        super.onResume()
        if (pendingEnable) {
            pendingEnable = false
            if (isAdminActive()) {
                // Admin was granted — complete the enable.
                pocketLockEnabled = true
                syncProximity()
                updateScreenKeepOn()
            }
            // Flutter polls getPocketLockStatus on resume (didChangeAppLifecycleState)
            // so no need to push from here.
        }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qth_helper/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPocketLock" -> {
                        val enable = call.argument<Boolean>("enabled") ?: false
                        if (enable && !isAdminActive()) {
                            // Launch Device Admin activation prompt.
                            pendingEnable = true
                            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                                putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComp)
                                putExtra(
                                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                    "QTH Dashboard needs Device Administrator access to lock " +
                                    "the screen when the phone is detected in a pocket."
                                )
                            }
                            startActivity(intent)
                            result.success(mapOf(
                                "enabled"       to false,
                                "adminActive"   to false,
                                "adminLaunched" to true
                            ))
                        } else {
                            pocketLockEnabled = enable
                            if (!enable) {
                                pocketHandler.removeCallbacks(sleepRunnable)
                                isNearby = false
                            }
                            syncProximity()
                            updateScreenKeepOn()
                            result.success(mapOf(
                                "enabled"       to pocketLockEnabled,
                                "adminActive"   to isAdminActive(),
                                "adminLaunched" to false
                            ))
                        }
                    }
                    "getPocketLockStatus" -> result.success(mapOf(
                        "enabled"     to pocketLockEnabled,
                        "adminActive" to isAdminActive()
                    ))
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
    }
}

// ── Device Admin receiver ─────────────────────────────────────────────────────
// A minimal DeviceAdminReceiver subclass — just the policy declaration in XML
// (res/xml/device_admin_receiver.xml) is what really matters.
class LockReceiver : DeviceAdminReceiver()

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
