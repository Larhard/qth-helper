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

    /** Play a single quiet test sequence (20 % volume, 3 s, then auto-stop). */
    fun test() {
        stop()
        mode = Mode.ALARM // prevents immediate re-entry
        prepareAudio(forTest = true)
        try {
            val pcm = alarmBuffer()
            val track = createLoopingTrack(pcm, volumeScale = 0.20f)
            track.write(pcm, 0, pcm.size)
            track.setLoopPoints(0, pcm.size, 3) // loop 3 times ≈ 6 s then stop
            track.play()
            audioTrack = track
        } catch (_: Exception) {}
        handler.postDelayed({ if (mode == Mode.ALARM) stop() }, 6_000L)
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

    /**
     * Warning: a single gentle "ping" at 880 Hz.
     * 200 ms tone, then 800 ms silence — one quiet nudge per second of the buffer.
     * Amplitude 28 % — wakes a light sleeper without alarming the whole crew.
     */
    private fun warningBuffer(): ShortArray = synthesise(1000, amplitude = 0.28) { t ->
        val cycle = t % 1.0
        if (cycle > 0.20) return@synthesise 0.0   // silence for rest of second
        // Soft envelope: fade out over the 200 ms to avoid click
        val env = 1.0 - (cycle / 0.20)
        sin(2 * PI * 880.0 * t) * env
    }

    /**
     * Alarm siren: two simultaneous sweeping tones separated by a tritone (√2 ≈ 1.414).
     * The tritone is the most dissonant interval in Western music ("diabolus in musica").
     *   f1: sweeps 400 → 1 200 Hz at 0.5 Hz (smooth cosine ramp)
     *   f2: f1 × √2 (tritone above) — creates severe beating/dissonance
     * Both at full amplitude then hard-clipped for added harshness.
     */
    private fun alarmBuffer(): ShortArray = synthesise(2000, amplitude = 1.0) { t ->
        // Smooth sweep using (1 - cos) ramp so the direction is always rising.
        val sweep = 0.5 - 0.5 * Math.cos(2 * PI * 0.5 * t)
        val freq  = 400.0 + 800.0 * sweep                    // 400 → 1200 Hz
        val f1    = sin(2 * PI * freq * t)
        val f2    = sin(2 * PI * freq * 1.4142 * t)           // tritone (√2 ratio)
        // Sum both tones at equal amplitude; hard-clip to ±0.9 for added buzz.
        (f1 + f2).coerceIn(-0.9, 0.9)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audio playback
    // ─────────────────────────────────────────────────────────────────────────

    private fun buildAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    /**
     * Set alarm stream to max volume (or 20 % for test) and acquire exclusive
     * audio focus before playing.
     */
    private fun prepareAudio(forTest: Boolean = false) {
        val targetVol = if (forTest) {
            (audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM) * 0.20).toInt().coerceAtLeast(1)
        } else {
            audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        }
        audioManager.setStreamVolume(AudioManager.STREAM_ALARM, targetVol, 0)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = android.media.AudioFocusRequest.Builder(
                if (forTest) AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                else AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
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

    /**
     * Force audio to the built-in speaker regardless of headphone/BT state.
     * Safety requirement: the alarm must be audible in the physical space
     * even if crew members are wearing headphones.
     * An additional default-routed track is created for headphone users.
     */
    private var speakerTrack: AudioTrack? = null

    private fun createLoopingTrack(pcm: ShortArray, volumeScale: Float = 1.0f): AudioTrack {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufBytes = maxOf(minBuf, pcm.size * 2)

        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
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
        if (volumeScale < 1.0f) track.setVolume(volumeScale)
        return track
    }

    /** Route track to the built-in speaker regardless of headphone/BT routing. */
    private fun forceToSpeaker(track: AudioTrack) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val spk = audioManager
                    .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (spk != null) track.setPreferredDevice(spk)
            } catch (_: Exception) {}
        }
    }

    private fun playPcm(pcm: ShortArray, forTest: Boolean = false) {
        stopAudio()
        prepareAudio(forTest)
        try {
            // Primary track: routed to built-in speaker so alarm is always audible.
            val primary = createLoopingTrack(pcm)
            forceToSpeaker(primary)
            primary.write(pcm, 0, pcm.size)
            primary.setLoopPoints(0, pcm.size, -1)
            primary.play()
            audioTrack = primary

            // Companion track: default routing (also plays through BT/headphones
            // if connected) so wearers are also alerted.
            if (!forTest) {
                val companion = createLoopingTrack(pcm, volumeScale = 0.85f)
                companion.write(pcm, 0, pcm.size)
                companion.setLoopPoints(0, pcm.size, -1)
                companion.play()
                speakerTrack = companion
            }
        } catch (_: Exception) {}
    }

    private fun playWarningBeep() = playPcm(warningBuffer())
    private fun playAlarmSiren()  = playPcm(alarmBuffer())

    private fun stopAudio() {
        try { audioTrack?.stop();   audioTrack?.release()   } catch (_: Exception) {}
        try { speakerTrack?.stop(); speakerTrack?.release() } catch (_: Exception) {}
        audioTrack = null
        speakerTrack = null

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
