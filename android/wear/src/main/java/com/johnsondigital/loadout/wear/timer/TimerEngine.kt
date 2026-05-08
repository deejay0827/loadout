// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/timer/TimerEngine.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Stage timer view-model for the Wear OS LoadOut companion (Feature 1).
// Mirrors iOS `TimerEngine.swift`. Runs a 1-second countdown using
// Kotlin coroutines, fires haptic + tone cues at warning checkpoints,
// and emits `timer_event` payloads to the phone so it can mirror state
// when foreground.
//
// Public surface:
//   * `enum class State` — `IDLE | RUNNING | PAUSED | FINISHED`.
//   * Compose-observable state via `mutableStateOf` / `mutableIntStateOf`:
//     `totalSec`, `remainingSec`, `state`, `quietMode`. All have public
//     getters and private setters.
//   * `fun toggleQuietMode(on: Boolean)` — persisted to
//     `wear_timer_prefs.quietMode`.
//   * `fun adjust(seconds: Int)` — only valid while idle; bumps total
//     duration (clamped to ≥5 s).
//   * `fun start()`, `pause()`, `resume()`, `reset()` — drive the state
//     machine.
//
// At every `start`, the engine clears the warning checkpoint set so
// repeat runs fire all warnings again. At every tick while running,
// the engine decrements `remainingSec`, checks the warning list, and
// transitions to `FINISHED` at zero.
//
// Last-used `totalSec` and `quietMode` persist to `SharedPreferences`
// under the `wear_timer_prefs` file.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Same role as iOS `TimerEngine.swift`. PRS / NRL / 3-Gun stages run
// on a tight clock; the watch's haptics + tone are more reliable than
// fumbling for the phone. The whole engine intentionally runs
// **entirely on the watch** — phone connectivity is optional, used
// only to mirror state to the phone.
//
// Splitting the engine out of `TimerScreen.kt` keeps the screen
// purely declarative (read state, emit user actions) while the engine
// owns timing, persistence, and audio. The engine extends `ViewModel`
// so it survives Compose configuration changes (rotation, theme
// switch) — Android's standard MVVM pattern.
//
// (For Compose newcomers: `mutableStateOf` is Compose's reactive
// primitive — a property declared with `var x by mutableStateOf(...)`
// will re-trigger any composable that reads `x` whenever `x` is
// reassigned. It's the equivalent of SwiftUI's `@Published` or React's
// `useState`. `mutableIntStateOf` is the int-specialised variant that
// avoids boxing on every tick.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Coroutines instead of `Timer`.** Android has many timer-like
//    APIs but `viewModelScope.launch { while (...) delay(1000) }` is
//    the Compose-friendly idiom. The coroutine is automatically
//    cancelled when the ViewModel is cleared. `delay(1000)` is a
//    suspending function that doesn't burn a thread; the runtime
//    schedules it on a single timer thread shared across all
//    coroutines.
//
// 2. **Haptics fire even in quiet mode.** Same rule as iOS: quiet
//    mode silences the SPEAKER, not the wrist. The user opts into
//    quiet mode specifically to get haptics-only — silencing both
//    would defeat the feature.
//
// 3. **`VibratorManager` vs `Vibrator` API split at API 31.** Android
//    refactored vibration in Android 12+: pre-31 you get a `Vibrator`
//    via `VIBRATOR_SERVICE`; 31+ you get a `VibratorManager` via
//    `VIBRATOR_MANAGER_SERVICE` and pull the default vibrator off
//    that. We branch on `Build.VERSION.SDK_INT` and the lazy property
//    caches whichever instance the OS gave us. The
//    `@Suppress("DEPRECATION")` is on the legacy fallback — required
//    because Kotlin's compiler flags the old API on newer SDKs even
//    when guarded by a runtime check.
//
// 4. **`ToneGenerator` MUST be released after use.** It owns native
//    audio resources. Failing to call `release()` leaks them across
//    timer runs and can eventually starve the audio system.
//    `viewModelScope.launch { delay; release }` is the deferred-release
//    pattern. The `delay(durMs + 50)` gives the tone room to play
//    before tearing down.
//
// 5. **`triggeredWarnings` is a `Set<Int>`, not a count.** Same logic
//    as iOS: each checkpoint fires exactly once per run, even after
//    pause/resume that crosses the checkpoint boundary.
//
// 6. **`emit` is best-effort and tolerates a null sender.** The watch
//    works fully without a phone connection — `sender` is nullable
//    by construction. Don't gate state changes on send-success.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — instantiates, passing a `PhoneDataLayerSender`
//   so timer events can mirror to the phone.
// - `screens/TimerScreen.kt` — reads every Compose state property and
//   calls the public methods on user gesture.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads / writes `SharedPreferences` file `wear_timer_prefs`.
// - Plays haptics via `Vibrator.vibrate(...)` (system service).
// - Plays speaker tones via `ToneGenerator` (only when `quietMode`
//   is off).
// - Calls `sender.send(...)` on every state transition — sends
//   `timer_event` payloads peer-to-peer to the phone via the
//   Wearable Data Layer. No HTTP, no analytics.

package com.johnsondigital.loadout.wear.timer

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.johnsondigital.loadout.wear.bridge.PhoneDataLayerSender
import com.johnsondigital.loadout.wear.bridge.WatchPaths
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Stage timer engine for the Wear OS LoadOut companion (mirrors
 * iOS TimerEngine.swift).
 *
 * Defaults:
 *   - 90 s total, adjustable in 30 s steps.
 *   - Warning beeps at 30, 10, 5 seconds remaining.
 *   - Final long beep at 0.
 *   - Wrist haptic + audio tone — both, unless quietMode is on.
 *
 * Persists last-used duration + quiet flag in app-level
 * SharedPreferences under `wear_timer_prefs`.
 */
class TimerEngine(
    private val context: Context,
    private val sender: PhoneDataLayerSender? = null,
) : ViewModel() {

    enum class State { IDLE, RUNNING, PAUSED, FINISHED }

    private val prefs = context.getSharedPreferences("wear_timer_prefs", Context.MODE_PRIVATE)
    private val kLastDuration = "lastDuration"
    private val kQuietMode = "quietMode"

    private val warningPoints = listOf(30, 10, 5)

    var totalSec by mutableIntStateOf(prefs.getInt(kLastDuration, 90))
        private set
    var remainingSec by mutableIntStateOf(totalSec)
        private set
    var state by mutableStateOf(State.IDLE)
        private set
    var quietMode by mutableStateOf(prefs.getBoolean(kQuietMode, false))
        private set

    private var tickJob: Job? = null
    private val triggeredWarnings = mutableSetOf<Int>()

    // Lazy haptic + audio handles.
    private val vibrator: Vibrator? by lazy {
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            val mgr = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            mgr?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    fun toggleQuietMode(on: Boolean) {
        quietMode = on
        prefs.edit().putBoolean(kQuietMode, on).apply()
    }

    fun adjust(seconds: Int) {
        if (state != State.IDLE) return
        totalSec = (totalSec + seconds).coerceAtLeast(5)
        remainingSec = totalSec
        prefs.edit().putInt(kLastDuration, totalSec).apply()
    }

    fun start() {
        if (state == State.RUNNING) return
        if (state == State.IDLE || state == State.FINISHED) {
            remainingSec = totalSec
            triggeredWarnings.clear()
        }
        state = State.RUNNING
        beep(Cue.START)
        emit("start", remainingSec, totalSec)
        scheduleTick()
    }

    fun pause() {
        if (state != State.RUNNING) return
        state = State.PAUSED
        tickJob?.cancel()
        emit("pause", remainingSec, totalSec)
    }

    fun resume() {
        if (state != State.PAUSED) return
        state = State.RUNNING
        emit("resume", remainingSec, totalSec)
        scheduleTick()
    }

    fun reset() {
        tickJob?.cancel()
        remainingSec = totalSec
        triggeredWarnings.clear()
        state = State.IDLE
        emit("reset", remainingSec, totalSec)
    }

    private fun scheduleTick() {
        tickJob?.cancel()
        tickJob = viewModelScope.launch {
            while (state == State.RUNNING) {
                delay(1000)
                if (state != State.RUNNING) break
                remainingSec -= 1
                if (warningPoints.contains(remainingSec) &&
                    !triggeredWarnings.contains(remainingSec)) {
                    triggeredWarnings.add(remainingSec)
                    beep(Cue.WARNING)
                    emit("warning", remainingSec, totalSec)
                }
                if (remainingSec <= 0) {
                    remainingSec = 0
                    state = State.FINISHED
                    beep(Cue.EXPIRED)
                    emit("expired", 0, totalSec)
                    break
                }
            }
        }
    }

    private enum class Cue { START, WARNING, EXPIRED }

    private fun beep(cue: Cue) {
        // Haptic always fires; quiet mode only suppresses audio.
        val effect = when (cue) {
            Cue.START -> VibrationEffect.createOneShot(80, VibrationEffect.DEFAULT_AMPLITUDE)
            Cue.WARNING -> VibrationEffect.createOneShot(60, VibrationEffect.DEFAULT_AMPLITUDE)
            Cue.EXPIRED -> VibrationEffect.createWaveform(
                longArrayOf(0, 120, 80, 120, 80, 220),
                intArrayOf(0, 255, 0, 255, 0, 255),
                -1
            )
        }
        try {
            vibrator?.vibrate(effect)
        } catch (_: Throwable) {
            // Some emulators don't expose a vibrator; haptics are best-effort.
        }

        if (quietMode) return

        // Speaker tone via ToneGenerator. Brief tone for warnings,
        // longer for the final.
        try {
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 100)
            val (toneType, durMs) = when (cue) {
                Cue.START -> Pair(ToneGenerator.TONE_PROP_BEEP, 180)
                Cue.WARNING -> Pair(ToneGenerator.TONE_PROP_BEEP, 100)
                Cue.EXPIRED -> Pair(ToneGenerator.TONE_PROP_BEEP2, 450)
            }
            tone.startTone(toneType, durMs)
            // ToneGenerator must be released after the tone plays.
            viewModelScope.launch {
                delay(durMs.toLong() + 50)
                tone.release()
            }
        } catch (_: Throwable) {
            // Audio failures are non-fatal; the haptic already fired.
        }
    }

    private fun emit(kind: String, remaining: Int, total: Int) {
        val payload = mutableMapOf<String, Any?>(
            "k" to kind,
            "at" to System.currentTimeMillis(),
            "rem" to remaining,
            "tot" to total
        )
        sender?.send(WatchPaths.TIMER_EVENT, payload)
    }

    override fun onCleared() {
        tickJob?.cancel()
        super.onCleared()
    }
}
