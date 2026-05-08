// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/screens/StageLogScreen.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `@Composable` for the Stage Log tab on the Wear OS LoadOut
// companion (Feature 3). Mirrors iOS `StageLogView.swift`. Three
// ways for the user to log a shot:
//
//   1. **Motion detection.** The injected `MotionDetector` polls the
//      accelerometer; when it surfaces `pendingShotPeakG`, this
//      composable shows a 5-second confirm prompt with Skip / Log
//      buttons. If the user does nothing, a `LaunchedEffect`-driven
//      timer auto-confirms.
//   2. **Manual tap.** A big "Log Shot" button always available when
//      no candidate is pending.
//   3. **Swipe gestures.** Drag right ≥18 px = log; drag left ≥18 px
//      = skip (advances DOPE without logging).
//
// After every log AND every skip, `WatchAppState.nextRow()` advances
// the DOPE cursor so the user sees the dial for the next shot.
//
// Public surface:
//   * `@Composable fun StageLogScreen(motion: MotionDetector,
//     sender: PhoneDataLayerSender)` — the screen body.
//
// Private composables:
//   * `ConfirmPrompt(peak, onLog, onDismiss)` — the 5-second confirm
//     UI for motion-detected candidates.
//   * `ManualBlock(onTap, nextRangeYd)` — the always-visible manual
//     log button + next-range hint.
//
// Private helper:
//   * `logShot(sender, source, peakG, rangeYd)` — builds and sends
//     the `log_shot` payload AND increments `WatchAppState.shotCount`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Stage Log is the highest-frequency interaction on the watch — at
// the line, the user fires multiple shots per minute. Combining
// motion + swipe + manual tap into one screen (rather than three
// separate screens) means the user never has to navigate to log a
// shot. The screen sits as page 2 of `MainActivity.AppPager`,
// reachable by one swipe.
//
// (For Compose newcomers: `LaunchedEffect(key)` runs the block once
// when the composable enters composition AND restarts it whenever
// `key` changes. It's the structured-concurrency replacement for the
// old "side-effect on first render" pattern. `DisposableEffect`
// gives you a `onDispose { ... }` block that runs when the
// composable LEAVES composition — perfect for sensor lifecycle.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`DisposableEffect(Unit)` is the right scope.** Pass `Unit` as
//    the key so the effect runs ONCE per composable lifetime — start
//    motion when the screen appears, stop when it leaves. Using a
//    key that changes (e.g. `motion`) would re-run on every
//    recomposition and constantly tear the sensor down.
//
// 2. **Auto-confirm uses `LaunchedEffect(pendingPeak)`.** The key is
//    the pending peak value; passing `pendingPeak` means the effect
//    re-launches whenever `pendingPeak` flips from non-null to a
//    DIFFERENT non-null (a follow-up shot). The 5-second
//    `delay(5000)` is the auto-confirm window. The follow-up
//    `if (motion.pendingShotPeakG != null)` check is a guard against
//    the user manually skipping during the delay.
//
// 3. **`detectHorizontalDragGestures` thresholds are 18 px.**
//    Smaller than iOS (24 pt) because Wear OS faces are typically
//    smaller than Apple Watches. 18 px is enough to distinguish a
//    swipe from a jitter-tap and small enough that gloved fingers
//    can hit it. Beware that `dragAmount` here is per-gesture, not
//    cumulative — a slow drag accumulates several events.
//
// 4. **`logShot` is a top-level helper, not a composable.** It runs
//    on the calling thread (the gesture handler's), which is fine
//    because `sender.send` itself dispatches to a single-thread
//    executor. Composable scoping rules would have wrapped it
//    awkwardly.
//
// 5. **`WatchAppState.incrementShotCount()` is called locally.** The
//    phone is the source of truth for historical shot counts (range
//    day records); the watch's count is per-stage, in-memory only.
//    We increment locally for immediate feedback, and the user's
//    next session-start on the phone re-syncs the official count.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — hosts as the third page in `AppPager`.
// - `motion/MotionDetector.kt` — passed in. Lifecycle managed via
//   `DisposableEffect`.
// - `bridge/PhoneDataLayerSender.kt` — passed in. Used to send
//   `log_shot` payloads to the phone.
// - `state/WatchAppState.kt` — read for `dopeSnapshot`, `rowCursor`,
//   `shotCount`. Mutated via `incrementShotCount`, `clearShotCount`,
//   `nextRow`.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Starts the accelerometer when the composable appears (via
//   `motion.start()`); stops on `onDispose`.
// - Logs shots via `sender.send(...)`, which queues a peer-to-peer
//   message to the phone (no HTTP).
// - Mutates `WatchAppState` (shot count, DOPE cursor).

package com.johnsondigital.loadout.wear.screens

import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import com.johnsondigital.loadout.wear.bridge.PhoneDataLayerSender
import com.johnsondigital.loadout.wear.bridge.ShotSource
import com.johnsondigital.loadout.wear.bridge.WatchPaths
import com.johnsondigital.loadout.wear.motion.MotionDetector
import com.johnsondigital.loadout.wear.state.WatchAppState
import kotlinx.coroutines.delay

/**
 * Shot-capture screen for Feature 3. Two ways to log:
 *   - motion: accelerometer detector fires a candidate; user has 5 s
 *     to confirm or skip (auto-confirm by default)
 *   - swipe right: log; swipe left: skip; tap "Log Shot" to log manually
 */
@Composable
fun StageLogScreen(
    motion: MotionDetector,
    sender: PhoneDataLayerSender,
) {
    val shotCount by WatchAppState.shotCount.collectAsState()
    val cursor by WatchAppState.rowCursor.collectAsState()
    val snapshot by WatchAppState.dopeSnapshot.collectAsState()
    val pendingPeak = motion.pendingShotPeakG

    DisposableEffect(Unit) {
        motion.start()
        onDispose { motion.stop() }
    }

    LaunchedEffect(pendingPeak) {
        if (pendingPeak != null) {
            delay(5000)
            // If still pending after 5 s, auto-confirm.
            if (motion.pendingShotPeakG != null) {
                val peak = motion.acknowledge()
                logShot(sender, ShotSource.MOTION, peak, snapshot?.rows?.getOrNull(cursor)?.rangeYd?.toDouble())
                WatchAppState.nextRow()
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 6.dp)
            .pointerInput(Unit) {
                detectHorizontalDragGestures { _, dragAmount ->
                    if (dragAmount > 18) {
                        logShot(sender, ShotSource.SWIPE, null,
                            snapshot?.rows?.getOrNull(cursor)?.rangeYd?.toDouble())
                        WatchAppState.nextRow()
                    } else if (dragAmount < -18) {
                        WatchAppState.nextRow()
                    }
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.fillMaxWidth(0.7f)) {
                Text(
                    text = "STAGE",
                    fontSize = 9.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colors.onBackground,
                )
                Text(
                    text = "$shotCount shot${if (shotCount == 1) "" else "s"}",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
            Button(
                onClick = { WatchAppState.clearShotCount() },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.secondaryButtonColors(
                    backgroundColor = Color(0xFF8E1B1B),
                ),
            ) { Text("Clr", fontSize = 9.sp) }
        }

        if (pendingPeak != null) {
            ConfirmPrompt(
                peak = pendingPeak,
                onLog = {
                    val peak = motion.acknowledge()
                    logShot(sender, ShotSource.MOTION, peak,
                        snapshot?.rows?.getOrNull(cursor)?.rangeYd?.toDouble())
                    WatchAppState.nextRow()
                },
                onDismiss = { motion.dismiss() },
            )
        } else {
            ManualBlock(
                onTap = {
                    logShot(sender, ShotSource.MANUAL, null,
                        snapshot?.rows?.getOrNull(cursor)?.rangeYd?.toDouble())
                    WatchAppState.nextRow()
                },
                nextRangeYd = snapshot?.rows?.getOrNull(cursor)?.rangeYd,
            )
        }
    }
}

@Composable
private fun ConfirmPrompt(peak: Double, onLog: () -> Unit, onDismiss: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = "Shot detected",
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFFFFA726),
        )
        Text(
            text = "%.1f g".format(peak),
            fontSize = 9.sp,
            color = MaterialTheme.colors.onBackground,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Button(
                onClick = onDismiss,
                colors = ButtonDefaults.secondaryButtonColors(),
                modifier = Modifier.fillMaxWidth(0.4f),
            ) { Text("Skip", fontSize = 11.sp) }
            Button(
                onClick = onLog,
                colors = ButtonDefaults.primaryButtonColors(
                    backgroundColor = Color(0xFF66BB6A),
                ),
                modifier = Modifier.fillMaxWidth(0.7f),
            ) { Text("Log", fontSize = 11.sp) }
        }
        Text(
            text = "Auto in 5s",
            fontSize = 8.sp,
            color = MaterialTheme.colors.onBackground,
        )
    }
}

@Composable
private fun ManualBlock(onTap: () -> Unit, nextRangeYd: Int?) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Button(
            onClick = onTap,
            colors = ButtonDefaults.primaryButtonColors(
                backgroundColor = Color(0xFF66BB6A),
            ),
            modifier = Modifier
                .fillMaxWidth(0.85f)
                .height(46.dp),
        ) {
            Text("Log Shot", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Text(
            text = if (nextRangeYd != null) "Next: $nextRangeYd yd" else "No DOPE",
            fontSize = 9.sp,
            color = MaterialTheme.colors.onBackground,
        )
        Text(
            text = "Swipe → log · ← skip",
            fontSize = 8.sp,
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
        )
    }
}

private fun logShot(
    sender: PhoneDataLayerSender,
    source: String,
    peakG: Double?,
    rangeYd: Double?,
) {
    val payload = mutableMapOf<String, Any?>(
        "at" to System.currentTimeMillis(),
        "src" to source,
    )
    if (peakG != null) payload["g"] = peakG
    if (rangeYd != null) payload["r"] = rangeYd
    sender.send(WatchPaths.LOG_SHOT, payload)
    WatchAppState.incrementShotCount()
}
