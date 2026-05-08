// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/screens/TimerScreen.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `@Composable` for the stage-timer tab on the Wear OS LoadOut
// companion (Feature 1). Reads a `TimerEngine` directly from the
// argument list (passed in from `MainActivity.AppPager`) and renders:
//
//   * Big numerals showing `m:ss`, color-coded by state (white →
//     orange at ≤10 s → red at ≤5 s → red on finish).
//   * State label below (READY · 1:30 / RUNNING / PAUSED / DONE).
//   * `-30` and `+30` adjuster buttons (only enabled while IDLE).
//   * Primary Start / Pause / Resume / Restart button, tinted by
//     state.
//   * Reset button + a sound/haptic toggle in a footer row.
//
// Public surface:
//   * `@Composable fun TimerScreen(engine: TimerEngine)` — the screen
//     body.
//
// Private composables:
//   * `CompactButton(...)` — small fixed-size button for the +30/-30/
//     reset row.
//
// Private helpers:
//   * `stateColor`, `primaryTint`, `primaryLabel`, `stateLabel`,
//     `formatMmSs` — compute the visual outputs from engine state.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One of three feature screens hosted by `MainActivity.AppPager`.
// Mirrors iOS `TimerView.swift`. Keeping the layout separate from
// `TimerEngine` lets the engine be unit-testable without a Compose
// host and lets the screen be redesigned without touching timing
// logic.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`engine` is passed as an argument, not collected from state.**
//    Compose's `@Composable` re-runs whenever observable state it
//    reads changes; the engine's `mutableStateOf`-backed properties
//    drive the recomposition. We READ properties directly off the
//    engine (`engine.state`, `engine.remainingSec`) rather than
//    going through `collectAsState` because the engine isn't a
//    Flow — it's a Compose-aware view-model that exposes properties
//    Compose tracks natively.
//
// 2. **Color thresholds match `TimerEngine` warning checkpoints.**
//    `≤5 s = red`, `≤10 s = orange` matches the engine's
//    `warningPoints = listOf(30, 10, 5)`. Diverge them and the
//    visual cue and the audio cue land at different times.
//
// 3. **`Switch.checked = !quiet`.** The toggle reads "Sound" when
//    on, "Quiet" when off — but the engine stores the inverse
//    (`quietMode = true` means quiet). Negating in the Switch +
//    re-negating in `onCheckedChange` keeps the user-facing label
//    intuitive without changing the engine semantics.
//
// 4. **`Color(0xFFFF5252)` etc. are hand-picked.** Wear OS Compose's
//    `MaterialTheme.colors` has a small palette; for the timer
//    state colors we hand-code reds/oranges/greens that read well
//    on a watch face in bright sunlight (the typical match
//    environment).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — hosts as the first page in `AppPager`.
// - `timer/TimerEngine.kt` — passed in as the argument; the screen
//   calls `start`, `pause`, `resume`, `reset`, `adjust`, and
//   `toggleQuietMode`.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None directly. All side effects (haptics, audio, sends to phone)
// happen inside the engine when the screen's button taps drive its
// methods.

package com.johnsondigital.loadout.wear.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Switch
import androidx.wear.compose.material.Text
import com.johnsondigital.loadout.wear.timer.TimerEngine

/**
 * Stage timer screen for Feature 1.
 *
 * Big numerals, +30/-30 buttons (only enabled while idle), and a
 * primary Start/Pause/Resume action that's color-coded by state.
 */
@Composable
fun TimerScreen(engine: TimerEngine) {
    val state = engine.state
    val remaining = engine.remainingSec
    val total = engine.totalSec
    val quiet = engine.quietMode

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Text(
            text = formatMmSs(remaining),
            color = stateColor(state, remaining),
            fontWeight = FontWeight.Bold,
            fontSize = 36.sp,
        )
        Text(
            text = stateLabel(state, total),
            color = MaterialTheme.colors.onBackground,
            fontSize = 11.sp,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            CompactButton(
                onClick = { engine.adjust(-30) },
                enabled = state == TimerEngine.State.IDLE,
            ) { Text("-30", fontSize = 11.sp) }
            CompactButton(
                onClick = { engine.adjust(30) },
                enabled = state == TimerEngine.State.IDLE,
            ) { Text("+30", fontSize = 11.sp) }
        }

        Button(
            onClick = {
                when (state) {
                    TimerEngine.State.IDLE,
                    TimerEngine.State.FINISHED -> engine.start()
                    TimerEngine.State.RUNNING -> engine.pause()
                    TimerEngine.State.PAUSED -> engine.resume()
                }
            },
            colors = ButtonDefaults.primaryButtonColors(
                backgroundColor = primaryTint(state),
            ),
            modifier = Modifier.fillMaxWidth(0.8f),
        ) {
            Text(primaryLabel(state), fontSize = 13.sp)
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CompactButton(
                onClick = { engine.reset() },
                enabled = state != TimerEngine.State.IDLE,
            ) { Text("↻", fontSize = 13.sp) }
            Switch(
                checked = !quiet,
                onCheckedChange = { engine.toggleQuietMode(!it) },
            )
            Text(if (quiet) "haptic" else "sound", fontSize = 9.sp)
        }
    }
}

@Composable
private fun CompactButton(
    onClick: () -> Unit,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(38.dp),
        colors = ButtonDefaults.secondaryButtonColors(),
    ) { content() }
}

private fun stateColor(state: TimerEngine.State, remaining: Int): Color {
    return when (state) {
        TimerEngine.State.IDLE -> Color.White
        TimerEngine.State.RUNNING -> when {
            remaining <= 5 -> Color(0xFFFF5252)
            remaining <= 10 -> Color(0xFFFFA726)
            else -> Color.White
        }
        TimerEngine.State.PAUSED -> Color(0xFF42A5F5)
        TimerEngine.State.FINISHED -> Color(0xFFFF5252)
    }
}

private fun primaryTint(state: TimerEngine.State): Color = when (state) {
    TimerEngine.State.IDLE,
    TimerEngine.State.FINISHED -> Color(0xFF66BB6A)
    TimerEngine.State.RUNNING -> Color(0xFFFFA726)
    TimerEngine.State.PAUSED -> Color(0xFF42A5F5)
}

private fun primaryLabel(state: TimerEngine.State) = when (state) {
    TimerEngine.State.IDLE -> "Start"
    TimerEngine.State.RUNNING -> "Pause"
    TimerEngine.State.PAUSED -> "Resume"
    TimerEngine.State.FINISHED -> "Restart"
}

private fun stateLabel(state: TimerEngine.State, total: Int) = when (state) {
    TimerEngine.State.IDLE -> "READY · ${formatMmSs(total)}"
    TimerEngine.State.RUNNING -> "RUNNING"
    TimerEngine.State.PAUSED -> "PAUSED"
    TimerEngine.State.FINISHED -> "DONE"
}

private fun formatMmSs(seconds: Int): String {
    val m = seconds / 60
    val s = seconds % 60
    return "%d:%02d".format(m, s)
}
