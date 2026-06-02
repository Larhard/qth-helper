package com.elgassia.qthdashboard

import android.content.Context
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Manages all hardware effects for the anchor alarm:
 *   Warning  — periodic gentle vibration + soft beep every ~8 s
 *   Alarm    — continuous strong vibration + loud looping alarm tone + flashlight strobe
 *
 * Both levels acquire a SCREEN_BRIGHT_WAKE_LOCK so the screen wakes up even
 * when the phone is locked (no additional permission beyond WAKE_LOCK needed).
 *
 * Audio uses AudioAttributes.USAGE_ALARM which bypasses Do-Not-Disturb on most
 * devices and overrides the alarm-stream volume to maximum.  No permission needed.
 *
 * Flashlight uses CameraManager.setTorchMode() — no CAMERA permission needed on
 * Android 6.0+.  Fails silently if the device has no torch.
 */
class AnchorAlarmManager(private val ctx: Context) {

    enum class Mode { NONE, WARNING, ALARM }

    private var mode = Mode.NONE
    private val handler = Handler(Looper.getMainLooper())

    // ── Vibrator ──────────────────────────────────────────────────────────────
    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    // ── Audio ─────────────────────────────────────────────────────────────────
    private var toneGen: ToneGenerator? = null
    private val audioManager by lazy { ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }

    // ── Flashlight ────────────────────────────────────────────────────────────
    private var torchCameraId: String? = null
    private val cameraManager by lazy {
        ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    }
    private var torchOn = false
    private val flashRunnable = object : Runnable {
        override fun run() {
            if (mode != Mode.ALARM) return
            torchOn = !torchOn
            setTorch(torchOn)
            handler.postDelayed(this, if (torchOn) 300L else 500L)
        }
    }

    // ── Wake lock ─────────────────────────────────────────────────────────────
    private var wakeLock: PowerManager.WakeLock? = null

    // ── Warning periodics ─────────────────────────────────────────────────────
    private val warningRunnable = object : Runnable {
        override fun run() {
            if (mode != Mode.WARNING) return
            vibrateShort()
            beepSoft()
            handler.postDelayed(this, 8_000L)
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    fun startWarning() {
        if (mode == Mode.WARNING) return
        stop()
        mode = Mode.WARNING
        acquireWakeLock()
        handler.post(warningRunnable)
    }

    fun startAlarm() {
        if (mode == Mode.ALARM) return
        stop()
        mode = Mode.ALARM
        acquireWakeLock()
        vibrateContinuous()
        startAlarmTone()
        handler.postDelayed(flashRunnable, 100L)
    }

    fun stop() {
        mode = Mode.NONE
        handler.removeCallbacks(warningRunnable)
        handler.removeCallbacks(flashRunnable)
        vibrator.cancel()
        stopTone()
        setTorch(false)
        torchOn = false
        releaseWakeLock()
    }

    // ── Vibration ─────────────────────────────────────────────────────────────

    private fun vibrateShort() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(
                longArrayOf(0L, 80L, 60L, 80L), -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(longArrayOf(0L, 80L, 60L, 80L), -1)
        }
    }

    private fun vibrateContinuous() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(
                longArrayOf(0L, 600L, 200L, 600L, 200L), 0)) // repeat
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(longArrayOf(0L, 600L, 200L, 600L, 200L), 0)
        }
    }

    // ── Audio ─────────────────────────────────────────────────────────────────

    private fun beepSoft() {
        try {
            if (toneGen == null) {
                toneGen = ToneGenerator(AudioManager.STREAM_ALARM, 50)
            }
            toneGen?.startTone(ToneGenerator.TONE_PROP_BEEP, 300)
        } catch (_: Exception) {}
    }

    private fun startAlarmTone() {
        try {
            // Override alarm stream to maximum volume.
            audioManager.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0,
            )
            if (toneGen == null) {
                toneGen = ToneGenerator(AudioManager.STREAM_ALARM, 100)
            }
            // TONE_CDMA_EMERGENCY_RINGBACK loops every ~2 s; we call it repeatedly
            // via a handler to keep it going.
            soundLoop()
        } catch (_: Exception) {}
    }

    private val soundLoopRunnable = object : Runnable {
        override fun run() {
            if (mode != Mode.ALARM) return
            try { toneGen?.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, 2000) }
            catch (_: Exception) {}
            handler.postDelayed(this, 2_200L)
        }
    }

    private fun soundLoop() {
        handler.removeCallbacks(soundLoopRunnable)
        handler.post(soundLoopRunnable)
    }

    private fun stopTone() {
        handler.removeCallbacks(soundLoopRunnable)
        try { toneGen?.stopTone(); toneGen?.release() } catch (_: Exception) {}
        toneGen = null
    }

    // ── Flashlight ────────────────────────────────────────────────────────────

    private fun setTorch(on: Boolean) {
        try {
            val id = torchCameraId ?: run {
                val found = cameraManager.cameraIdList.firstOrNull() ?: return
                torchCameraId = found
                found
            }
            cameraManager.setTorchMode(id, on)
        } catch (_: Exception) {}
    }

    // ── Wake lock ─────────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "QTHDashboard:AnchorAlarm"
            )
            wakeLock?.acquire(10 * 60 * 1000L) // auto-release after 10 min safety cap
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
    }
}
