package com.elgassia.qthdashboard

import android.content.Context
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
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
 * Process-wide singleton hardware driver for the anchor alarm.
 *
 * CRITICAL: there must be exactly ONE instance per process.  Both MainActivity
 * and AnchorMonitorService obtain it via [getInstance].  Two instances would each
 * request AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE and kick each other out, producing
 * the start/stop "breakup" that field testing reported.
 *
 * Audio engine: Android AudioTrack (not ToneGenerator — it has focus-conflict
 * bugs when the screen is on or another stream holds focus).
 *
 * Guaranteed loud in all conditions:
 *   1. Exclusive audio focus is held until stop(); transient focus changes are
 *      ignored (the listener is a no-op) so the alarm never self-silences.
 *   2. STREAM_ALARM is forced to max volume before play — overrides silent/mute.
 *   3. USAGE_ALARM bypasses DND "Priority Only".
 *   4. Two tracks: one pinned to the built-in speaker (always audible in the
 *      physical space) and — only when an external output is connected — a
 *      companion track on the default route (so headphone/BT wearers also hear).
 *
 * Sound design:
 *   Warning — a single soft 880 Hz ping ONCE every 8 s (gentle nudge, one-shot).
 *   Alarm   — continuous looping siren: two tones a tritone (√2) apart sweeping
 *             400→1200 Hz, hard-clipped.  Maximally dissonant and harsh.
 */
class AnchorAlarmManager private constructor(private val appCtx: Context) {

    companion object {
        @Volatile private var instance: AnchorAlarmManager? = null
        fun getInstance(ctx: Context): AnchorAlarmManager =
            instance ?: synchronized(this) {
                instance ?: AnchorAlarmManager(ctx.applicationContext).also { instance = it }
            }
    }

    private enum class Mode { NONE, WARNING, ALARM, TEST }

    private var mode = Mode.NONE
    private val handler = Handler(Looper.getMainLooper())
    private val sampleRate = 44100

    val isTesting: Boolean get() = mode == Mode.TEST

    // ── Audio ─────────────────────────────────────────────────────────────────
    private val audioManager by lazy { appCtx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private var loopTrack: AudioTrack? = null      // continuous alarm/test track (speaker)
    private var loopCompanion: AudioTrack? = null  // optional headphone/BT track (non-blocking)
    private var audioFocusRequest: android.media.AudioFocusRequest? = null
    // Keep one-shot warning tracks alive until they finish, then release.
    private val oneShotTracks = mutableListOf<AudioTrack>()
    // Continuous playback = MODE_STREAM fed by ONE max-priority synth thread.
    // (MODE_STATIC + setLoopPoints glitches; two tracks comb-filter on one speaker.)
    @Volatile private var feeding = false
    private var feederThread: Thread? = null

    // Alarm focus changes are ignored — an alarm must keep sounding regardless.
    private val focusListener = AudioManager.OnAudioFocusChangeListener { /* no-op */ }

    // ── Vibrator ──────────────────────────────────────────────────────────────
    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (appCtx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            appCtx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    // ── Flashlight ────────────────────────────────────────────────────────────
    private var torchCameraId: String? = null
    private val cameraManager by lazy { appCtx.getSystemService(Context.CAMERA_SERVICE) as CameraManager }
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
            playOnce(warningBuffer())
            handler.postDelayed(this, 8_000L) // one gentle ping every 8 s
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
        handler.post(warningRunnable) // fires immediately, then every 8 s
    }

    fun startAlarm() {
        if (mode == Mode.ALARM) return
        stop()
        mode = Mode.ALARM
        acquireWakeLock()
        vibrateContinuous()
        startAlarmSynth(maxVolume = true, volumeScale = 1.0f)
        handler.postDelayed(flashRunnable, 100L)
    }

    /** Toggle a quiet (20 %) looping test that plays from all outputs. */
    fun toggleTest() {
        if (mode == Mode.TEST) { stop(); return }
        stop()
        mode = Mode.TEST
        startAlarmSynth(maxVolume = false, volumeScale = 0.20f)
        vibrateShort()
        // Safety auto-stop after 60 s in case the user forgets.
        handler.postDelayed({ if (mode == Mode.TEST) stop() }, 60_000L)
    }

    fun stop() {
        mode = Mode.NONE
        handler.removeCallbacks(warningRunnable)
        handler.removeCallbacks(flashRunnable)
        stopAudio()
        try { vibrator.cancel() } catch (_: Exception) {}
        setTorch(false)
        torchOn = false
        releaseWakeLock()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PCM synthesis
    // ─────────────────────────────────────────────────────────────────────────

    private fun synthesise(durationMs: Int, amplitude: Double, block: (t: Double) -> Double): ShortArray {
        val numSamples = sampleRate * durationMs / 1000
        val buf = ShortArray(numSamples)
        for (i in 0 until numSamples) {
            val t = i.toDouble() / sampleRate
            val s = (block(t) * amplitude).coerceIn(-1.0, 1.0)
            buf[i] = (s * Short.MAX_VALUE).roundToInt().toShort()
        }
        return buf
    }

    /** Single 880 Hz ping, 250 ms with a smooth fade-out — gentle, one-shot. */
    private fun warningBuffer(): ShortArray = synthesise(250, 0.32) { t ->
        val env = 1.0 - (t / 0.25)            // linear fade across the 250 ms
        sin(2 * PI * 880.0 * t) * env
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audio playback
    // ─────────────────────────────────────────────────────────────────────────

    private fun buildAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    private fun requestFocus(exclusive: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (audioFocusRequest != null) return // already held
            val req = android.media.AudioFocusRequest.Builder(
                if (exclusive) AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
                else AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
                .setAudioAttributes(buildAudioAttributes())
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            audioManager.requestAudioFocus(req)
            audioFocusRequest = req
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_ALARM,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
        }
    }

    private fun forceMaxAlarmVolume() {
        audioManager.setStreamVolume(
            AudioManager.STREAM_ALARM,
            audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM),
            0,
        )
    }

    private fun forceMaxAlarmVolumeIf(maxVolume: Boolean) { if (maxVolume) forceMaxAlarmVolume() }

    /**
     * Pin a track to the BUILT-IN SPEAKER regardless of headphone/BT routing.
     * Safety: the alarm must always sound in the physical space, even if the crew
     * is wearing headphones (the dangerous case is sound going ONLY to headphones).
     * A single speaker-pinned track also avoids the comb-filtering / "duplicated"
     * artefact that two simultaneous tracks on one speaker produce.
     */
    private fun pinToSpeaker(track: AudioTrack) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val spk = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (spk != null) track.setPreferredDevice(spk)
            } catch (_: Exception) {}
        }
    }

    /** Create a MODE_STREAM track with a generous buffer (~0.5 s of headroom). */
    private fun newStreamTrack(volumeScale: Float): AudioTrack {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufBytes = maxOf(minBuf, sampleRate) // ~0.5 s (sampleRate shorts = sampleRate*2 bytes)
        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(buildAudioAttributes())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(AudioManager.STREAM_ALARM, sampleRate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                bufBytes, AudioTrack.MODE_STREAM)
        }
        if (volumeScale < 1.0f) track.setVolume(volumeScale)
        return track
    }

    /** True when headphones / Bluetooth / USB audio output is connected. */
    private fun hasExternalOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO  ||
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET    ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
            }
        } catch (_: Exception) { false }
    }

    /**
     * Continuous alarm siren via ON-THE-FLY synthesis (no looping buffer).
     *
     * A dedicated max-priority thread generates samples with persistent phase
     * accumulators, so there is NEVER a loop-boundary discontinuity — the source
     * of the "breaking up" artefact.
     *
     * Output routing:
     *   • Primary track is pinned to the BUILT-IN SPEAKER (blocking writes pace
     *     the loop) — always audible in the room, even with headphones on.
     *   • A companion track on the DEFAULT route is added ONLY when an external
     *     output (BT/wired/USB) is connected, fed with NON-BLOCKING writes so it
     *     can never stall the speaker.  Because the two tracks then play to
     *     DIFFERENT physical outputs there is no comb-filtering / "duplicated"
     *     sound (the bug was two tracks on the one speaker).
     *
     * Timbre: two oscillators a tritone (√2) apart, the fundamental sweeping
     * 400→1200 Hz at 0.5 Hz, summed and hard-clipped — deliberately harsh.
     */
    private fun startAlarmSynth(maxVolume: Boolean, volumeScale: Float) {
        stopAudio()
        forceMaxAlarmVolumeIf(maxVolume)
        requestFocus(exclusive = maxVolume)
        feeding = true
        try {
            val speaker = newStreamTrack(volumeScale)
            pinToSpeaker(speaker)
            speaker.play()
            loopTrack = speaker

            val companion = if (hasExternalOutput()) {
                newStreamTrack(volumeScale).also { it.play(); loopCompanion = it }
            } else null

            feederThread = Thread {
                val twoPi = 2 * Math.PI
                var phase1 = 0.0
                var phase2 = 0.0
                var n = 0L
                val chunk = ShortArray(2048)
                try {
                    while (feeding) {
                        for (i in chunk.indices) {
                            val t = n / sampleRate.toDouble()
                            val sweep = 0.5 - 0.5 * Math.cos(twoPi * 0.5 * t) // 0..1 @ 0.5 Hz
                            val f1 = 400.0 + 800.0 * sweep
                            phase1 += twoPi * f1 / sampleRate
                            phase2 += twoPi * (f1 * 1.4142) / sampleRate
                            if (phase1 > twoPi) phase1 -= twoPi
                            if (phase2 > twoPi) phase2 -= twoPi
                            var s = Math.sin(phase1) + Math.sin(phase2)
                            if (s > 0.9) s = 0.9 else if (s < -0.9) s = -0.9
                            chunk[i] = (s * Short.MAX_VALUE).toInt().toShort()
                            n++
                        }
                        if (speaker.write(chunk, 0, chunk.size) < 0) break // blocking — paces loop
                        // Best-effort feed to headphones; never blocks the speaker.
                        companion?.write(chunk, 0, chunk.size, AudioTrack.WRITE_NON_BLOCKING)
                    }
                } catch (_: Exception) {}
            }.apply { isDaemon = true; priority = Thread.MAX_PRIORITY; start() }
        } catch (_: Exception) {}
    }

    /** One-shot playback (warning ping) — single speaker-pinned track, auto-released. */
    private fun playOnce(pcm: ShortArray) {
        forceMaxAlarmVolume()
        requestFocus(exclusive = false)
        val durationMs = (pcm.size.toLong() * 1000L / sampleRate) + 250L
        try {
            val track = newStreamTrack(1.0f)
            pinToSpeaker(track)
            track.play()
            track.write(pcm, 0, pcm.size)  // blocking; buffer plays out
            oneShotTracks.add(track)
            handler.postDelayed({ releaseOneShot(track) }, durationMs)
        } catch (_: Exception) {}
    }

    private fun releaseOneShot(track: AudioTrack) {
        try { track.stop(); track.release() } catch (_: Exception) {}
        oneShotTracks.remove(track)
    }

    private fun stopAudio() {
        feeding = false
        // Stopping the tracks unblocks the feeder thread parked in write().
        try { loopTrack?.stop() } catch (_: Exception) {}
        try { loopCompanion?.stop() } catch (_: Exception) {}
        try { feederThread?.join(200) } catch (_: Exception) {}
        feederThread = null
        try { loopTrack?.release() } catch (_: Exception) {}
        try { loopCompanion?.release() } catch (_: Exception) {}
        loopTrack = null
        loopCompanion = null
        for (t in oneShotTracks.toList()) { try { t.stop(); t.release() } catch (_: Exception) {} }
        oneShotTracks.clear()
        abandonFocus()
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        audioFocusRequest = null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Vibration / flashlight / wake lock
    // ─────────────────────────────────────────────────────────────────────────

    private fun vibrateShort() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0L, 80L, 60L, 80L), -1))
        } else {
            @Suppress("DEPRECATION") vibrator.vibrate(longArrayOf(0L, 80L, 60L, 80L), -1)
        }
    }

    private fun vibrateContinuous() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0L, 600L, 200L, 600L, 200L), 0))
        } else {
            @Suppress("DEPRECATION") vibrator.vibrate(longArrayOf(0L, 600L, 200L, 600L, 200L), 0)
        }
    }

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

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = appCtx.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "QTHDashboard:AnchorAlarm")
            wakeLock?.acquire(10 * 60 * 1000L)
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
    }
}
