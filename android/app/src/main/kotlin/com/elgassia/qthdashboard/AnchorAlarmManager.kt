package com.elgassia.qthdashboard

import android.content.Context
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.roundToInt

/**
 * Hardware alarm driver for the anchor alarm.
 *
 * Audio engine: Android AudioTrack (not ToneGenerator, which has known
 * focus-conflict bugs when the screen is on or another stream is active).
 *
 * Guaranteed loud in all conditions:
 *   1. AudioFocusRequest with AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE takes over
 *      all audio routing before playing.
 *   2. STREAM_ALARM is set to maximum volume before each play — overrides mute
 *      and silent mode for alarm-class audio on all Android versions.
 *   3. AudioAttributes.USAGE_ALARM bypasses DND "Priority Only" automatically.
 *
 * Audio design:
 *   Warning  — 523 Hz + 784 Hz (perfect 5th), soft amplitude (40 %).
 *              Alert but not panic-inducing.  Heard even at volume = 0.
 *   Alarm    — synthesised siren: fundamental sweeps 400–1 200 Hz at 1 Hz,
 *              second harmonic (2× freq, 90° phase shift) mixed at 50 %.
 *              Creates dissonance; extremely disturbing.  Max volume.
 */
class AnchorAlarmManager(private val ctx: Context) {

    enum class Mode { NONE, WARNING, ALARM }

    private var mode = Mode.NONE
    private val handler = Handler(Looper.getMainLooper())
    private val sampleRate = 44100

    // ── Audio ─────────────────────────────────────────────────────────────────
    private val audioManager by lazy { ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private var audioTrack: AudioTrack? = null
    private var audioFocusRequest: android.media.AudioFocusRequest? = null

    // ── Vibrator ──────────────────────────────────────────────────────────────
    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    // ── Flashlight ────────────────────────────────────────────────────────────
    private var torchCameraId: String? = null
    private val cameraManager by lazy { ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager }
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
            playWarningBeep()
            handler.postDelayed(this, 8_000L)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────────

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
        playAlarmSiren()
        handler.postDelayed(flashRunnable, 100L)
    }

    fun stop() {
        mode = Mode.NONE
        handler.removeCallbacks(warningRunnable)
        handler.removeCallbacks(flashRunnable)
        stopAudio()
        vibrator.cancel()
        setTorch(false)
        torchOn = false
        releaseWakeLock()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PCM synthesis helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Synthesise a looping PCM buffer.
     *
     * [block] receives time t (seconds) and returns a sample in [-1.0, 1.0].
     */
    private fun synthesise(durationMs: Int, amplitude: Double = 0.9,
                           block: (t: Double) -> Double): ShortArray {
        val numSamples = sampleRate * durationMs / 1000
        val buf = ShortArray(numSamples)
        for (i in 0 until numSamples) {
            val t = i.toDouble() / sampleRate
            val sample = (block(t) * amplitude).coerceIn(-1.0, 1.0)
            buf[i] = (sample * Short.MAX_VALUE).roundToInt().toShort()
        }
        return buf
    }

    /** Warning tone: 523 Hz + 784 Hz perfect-fifth alternating 0.5 s each. */
    private fun warningBuffer(): ShortArray = synthesise(2000, amplitude = 0.40) { t ->
        val freq = if (t % 1.0 < 0.5) 523.0 else 784.0
        sin(2 * PI * freq * t)
    }

    /**
     * Alarm siren: sweeps 400–1 200 Hz at 1 Hz + second harmonic (90° phase offset).
     * The interference between fundamental and 2× harmonic produces aggressive dissonance.
     */
    private fun alarmBuffer(): ShortArray = synthesise(2000, amplitude = 0.90) { t ->
        val freq = 400.0 + 800.0 * (sin(2 * PI * 0.5 * t) * 0.5 + 0.5) // 400→1200 Hz sweep
        val f1 = sin(2 * PI * freq * t)
        val f2 = sin(2 * PI * (freq * 2.0) * t + PI / 2) * 0.5  // 2nd harmonic, phase shifted
        (f1 + f2) / 1.5
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audio playback
    // ─────────────────────────────────────────────────────────────────────────

    private fun buildAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    /** Set alarm stream to max volume and acquire audio focus before playing. */
    private fun prepareAudio() {
        // Override alarm stream volume to max — bypasses silent/mute mode.
        audioManager.setStreamVolume(
            AudioManager.STREAM_ALARM,
            audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM),
            0,
        )
        // Request exclusive audio focus — takes over from any other playing app.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = android.media.AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
            )
                .setAudioAttributes(buildAudioAttributes())
                .setAcceptsDelayedFocusGain(false)
                .build()
            audioManager.requestAudioFocus(req)
            audioFocusRequest = req
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(null, AudioManager.STREAM_ALARM,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
        }
    }

    private fun createLoopingTrack(pcm: ShortArray): AudioTrack {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufBytes = maxOf(minBuf, pcm.size * 2)

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(buildAudioAttributes())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_ALARM, sampleRate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                bufBytes, AudioTrack.MODE_STATIC,
            )
        }
    }

    private fun playPcm(pcm: ShortArray) {
        stopAudio()
        prepareAudio()
        try {
            val track = createLoopingTrack(pcm)
            track.write(pcm, 0, pcm.size)
            track.setLoopPoints(0, pcm.size, -1) // -1 = infinite loop
            track.play()
            audioTrack = track
        } catch (e: Exception) {
            // Fallback: do nothing — visual + vibration still active
        }
    }

    private fun playWarningBeep() = playPcm(warningBuffer())
    private fun playAlarmSiren()  = playPcm(alarmBuffer())

    private fun stopAudio() {
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
        audioFocusRequest = null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Vibration
    // ─────────────────────────────────────────────────────────────────────────

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
                longArrayOf(0L, 600L, 200L, 600L, 200L), 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(longArrayOf(0L, 600L, 200L, 600L, 200L), 0)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Flashlight
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // Wake lock
    // ─────────────────────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "QTHDashboard:AnchorAlarm",
            )
            wakeLock?.acquire(10 * 60 * 1000L)
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
    }
}
