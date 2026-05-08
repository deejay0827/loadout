// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/motion/MotionDetector.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Threshold-based shot detector for the Wear OS LoadOut companion.
// Mirrors `MotionDetector.swift` on the watchOS side. Polls the
// accelerometer at ~50 Hz, computes the total acceleration vector
// magnitude in g, and fires a candidate "shot" event when the
// magnitude stays above `thresholdG` for at least 50 ms.
//
// Public surface (Compose-observable state via `mutableStateOf`):
//   * `thresholdG: Double` — user-adjustable via Stage Log settings
//     (3.0..10.0 g, default 5.0). Persists to `SharedPreferences`
//     under `wear_motion_prefs.thresholdG`.
//   * `pendingShotPeakG: Double?` — non-null after a candidate is
//     detected. The Stage Log composable shows a 5-second confirm
//     prompt when this changes.
//   * `liveMagnitude: Double` — instantaneous reading (1.0 g =
//     stationary).
//   * `isRunning: Boolean` — lifecycle flag.
//   * `fun start()`, `stop()`, `acknowledge()`, `dismiss()` — drive
//     the lifecycle and consume candidates.
//   * `fun updateThreshold(value: Double)` — clamps to [3.0, 10.0]
//     before persisting.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same role as iOS `MotionDetector.swift`. Rifle recoil shows up on
// the wrist as a brief, high-magnitude transient (~5–10 g for a few
// milliseconds). Stage Log uses this to auto-log shots without making
// the user tap their watch every time they fire.
//
// The class extends `ViewModel` so its state survives Compose
// configuration changes; `onCleared` calls `stop()` so we never leak
// a registered SensorEventListener across rotations.
//
// (For Android newcomers: `SensorManager` is the OS service for
// hardware sensors. `registerListener(...)` starts pushing samples on
// the main thread (or a specified Handler); the listener gets
// `onSensorChanged` for each sample. Always pair `registerListener`
// with `unregisterListener` — leaving listeners attached drains the
// battery 24/7.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Android reports m/s², not g.** Apple's CoreMotion returns
//    g-units directly; Android's `Sensor.TYPE_ACCELEROMETER` returns
//    m/s² (with gravity included). We divide by 9.80665 to convert
//    so the threshold semantics match the iOS sibling. If you
//    rewrite this, double-check the units against the iOS file —
//    using m/s² as the threshold would mean recoil never trips.
//
// 2. **`SAMPLE_INTERVAL_US = 20_000` ≈ 50 Hz.** Android's sensor
//    rate is a HINT, not a guarantee; the OS may deliver samples
//    faster or slower. 50 Hz is a sweet spot — fast enough to catch
//    the 50 ms peak window, slow enough to be battery-friendly.
//    Don't go to `SENSOR_DELAY_FASTEST` here — it'll burn battery
//    for marginal accuracy gains.
//
// 3. **Sustained-peak rule rejects single-sample spikes.** Same as
//    iOS: real recoil HOLDS above the threshold for multiple samples
//    (~50 ms = 2-3 samples at 50 Hz). Single-sample spikes (clapping
//    the wrist on a bench) get filtered out.
//
// 4. **Debounce prevents follow-up double-counting.** After a shot
//    fires, `lastEventAt` is set; subsequent threshold crossings
//    within `SETTLE_MS = 400` are ignored. PRS / 3-Gun split times
//    bottom out around 0.6 s, so 400 ms is well under.
//
// 5. **`onAccuracyChanged` is required by the interface.** Even if
//    we don't care about accuracy callbacks, omitting the override
//    would fail to compile because `SensorEventListener` is an
//    interface with two abstract methods.
//
// 6. **`stop()` resets state but leaves `thresholdG` alone.** A
//    user who tweaked the threshold to 7.0 g shouldn't have it
//    reset on a screen change. The stop is idempotent.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — instantiates a singleton motion detector and
//   passes it into `StageLogScreen`.
// - `screens/StageLogScreen.kt` — calls `start()` / `stop()` from
//   `DisposableEffect`, reads `pendingShotPeakG` to drive the confirm
//   UI, and calls `acknowledge()` / `dismiss()` from button taps and
//   the auto-confirm timer.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - On `start()`: registers a SensorEventListener with `SensorManager`,
//   which begins delivering ~50 Hz samples and runs the watch's
//   accelerometer (small but non-zero battery cost).
// - On `stop()`: unregisters; battery returns to baseline.
// - Reads / writes `SharedPreferences` file `wear_motion_prefs`.
// - No HTTP, no analytics. The Stage Log screen is what eventually
//   emits a `log_shot` payload via `PhoneDataLayerSender`.

package com.johnsondigital.loadout.wear.motion

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import kotlin.math.sqrt

/**
 * Threshold-based shot detection for the Wear OS LoadOut companion.
 * Mirrors `MotionDetector.swift` on the watchOS side.
 *
 * Rifle recoil shows as a brief, high-magnitude transient on the
 * watch's accelerometer. We treat any sustained spike above
 * [thresholdG] as a candidate shot, with a short settle window
 * before the next event can fire.
 *
 * Privacy: this class reads the accelerometer locally. No HTTP, no
 * persistence beyond the watch's own RAM (and the user's threshold
 * preference in SharedPreferences). See CLAUDE.md §15.
 */
class MotionDetector(private val context: Context) : ViewModel(), SensorEventListener {

    companion object {
        private const val TAG = "MotionDetector"
        private const val PREFS_KEY = "wear_motion_prefs"
        private const val PREF_THRESHOLD = "thresholdG"
        private const val SAMPLE_INTERVAL_US = 20_000  // ~50 Hz
        private const val SETTLE_MS = 400L
        private const val MIN_PEAK_MS = 50L
    }

    private val prefs = context.getSharedPreferences(PREFS_KEY, Context.MODE_PRIVATE)
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    var thresholdG by mutableDoubleStateOf(
        prefs.getFloat(PREF_THRESHOLD, 5.0f).toDouble()
    )
        private set

    var pendingShotPeakG by mutableStateOf<Double?>(null)
        private set

    var liveMagnitude by mutableDoubleStateOf(1.0)
        private set

    var isRunning by mutableStateOf(false)
        private set

    private var lastEventAt: Long = 0
    private var aboveSinceMs: Long = 0
    private var currentPeak: Double = 0.0

    fun updateThreshold(value: Double) {
        thresholdG = value.coerceIn(3.0, 10.0)
        prefs.edit().putFloat(PREF_THRESHOLD, thresholdG.toFloat()).apply()
    }

    fun start() {
        if (isRunning) return
        val sm = sensorManager ?: return
        val sensor = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        sm.registerListener(this, sensor, SAMPLE_INTERVAL_US)
        isRunning = true
    }

    fun stop() {
        sensorManager?.unregisterListener(this)
        isRunning = false
        aboveSinceMs = 0
        currentPeak = 0.0
        liveMagnitude = 1.0
    }

    fun acknowledge(): Double? {
        val peak = pendingShotPeakG
        pendingShotPeakG = null
        return peak
    }

    fun dismiss() {
        pendingShotPeakG = null
    }

    // SensorEventListener -------------------------------------------------

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return
        // Android reports m/s². Convert to g (1g ≈ 9.80665).
        val ax = event.values[0]
        val ay = event.values[1]
        val az = event.values[2]
        val magMs2 = sqrt((ax * ax + ay * ay + az * az).toDouble())
        val magG = magMs2 / 9.80665
        liveMagnitude = magG

        if (magG >= thresholdG) {
            if (aboveSinceMs == 0L) aboveSinceMs = System.currentTimeMillis()
            currentPeak = maxOf(currentPeak, magG)
            val held = System.currentTimeMillis() - aboveSinceMs
            if (held >= MIN_PEAK_MS) {
                fireCandidate(currentPeak)
            }
        } else {
            aboveSinceMs = 0
            currentPeak = 0.0
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op.
    }

    private fun fireCandidate(peak: Double) {
        val now = System.currentTimeMillis()
        if (now - lastEventAt < SETTLE_MS) return
        lastEventAt = now
        aboveSinceMs = 0
        currentPeak = 0.0
        pendingShotPeakG = peak
        Log.d(TAG, "candidate shot detected, peak=$peak g")
    }

    override fun onCleared() {
        stop()
        super.onCleared()
    }
}
