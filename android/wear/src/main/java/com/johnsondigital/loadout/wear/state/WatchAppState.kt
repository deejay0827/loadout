// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/state/WatchAppState.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Process-scoped singleton that holds the latest snapshots received
// from the phone, plus the user's current scroll position in the DOPE
// ladder and the per-stage shot count.
//
// Public surface (`object WatchAppState`):
//   * `val dopeSnapshot: StateFlow<DopeSnapshot?>` — latest DOPE
//     payload from the phone, or null until the first arrives.
//   * `val activeLoad: StateFlow<ActiveLoadSnapshot?>` — latest active
//     recipe summary.
//   * `val rowCursor: StateFlow<Int>` — 0-based index into
//     `dopeSnapshot.rows`; advanced by `nextRow()` / `previousRow()`,
//     clamped when a new snapshot lands.
//   * `val shotCount: StateFlow<Int>` — per-stage shot count.
//   * `fun setDope(snap)`, `setActiveLoad(snap)` — called from the
//     listener service.
//   * `fun nextRow()`, `previousRow()`, `currentRow()` — DOPE cursor
//     navigation.
//   * `fun incrementShotCount()`, `clearShotCount()` — Stage Log
//     bookkeeping.
//
// Each value is wrapped in a `MutableStateFlow` (private) backed by
// a public read-only `StateFlow` (`asStateFlow()`). Composables read
// state with `.collectAsState()`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The Wear OS Data Layer listener (`PhoneDataLayerListener`) runs as
// a `WearableListenerService` — a backgrounded service that Android
// can launch even when the activity is closed. The listener doesn't
// have direct access to the activity's view-models, so we need a
// process-singleton that BOTH can talk to.
//
// When the activity IS open, the service runs in the same process as
// the activity, so `setDope` mutations propagate to the UI through
// the normal StateFlow plumbing. When the activity is closed, the
// service writes into a separate in-memory state that's discarded
// when the process dies — fine, because the next phone push will
// repopulate on demand.
//
// (For Kotlin/Compose newcomers: a top-level `object` in Kotlin
// declares a singleton — it's the natural fit for "one shared
// state holder per process". `StateFlow` is the kotlin-coroutines
// reactive primitive Compose loves: `val ui by flow.collectAsState()`
// causes the composable to recompose whenever the flow emits a new
// value.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Cursor clamping after a new snapshot.** `setDope` may receive
//    a snapshot with FEWER rows than the previous one (e.g. the user
//    deleted a saved range bin on the phone). If `rowCursor` was
//    pointing at index 12 and the new snapshot has 8 rows, the
//    composable would render `rows[12]` as null and crash. The
//    clamp `if (_rowCursor.value >= snap.rows.size) ...` prevents
//    that. Same trick on `previousRow()` / `nextRow()` boundary
//    checks.
//
// 2. **Process-singleton vs view-model.** A `ViewModel` would be
//    cleaner from an MVVM-purist view, but ViewModels are scoped to
//    the activity and CAN'T be reached from a service that runs
//    when the activity is closed. The `object` singleton is the
//    only pattern that satisfies both consumers.
//
// 3. **`shotCount` is in-memory only.** Same logic as iOS
//    `ShotLogger.swift` — the count represents the active stage and
//    resets on cold launch. Persisting it would mean the user opens
//    the app the next morning and sees yesterday's count.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `bridge/PhoneDataLayerListener.kt` — calls `setDope` and
//   `setActiveLoad` on every received payload.
// - `screens/DopeScreen.kt` — reads `dopeSnapshot` and `rowCursor`
//   via `collectAsState()`; calls `nextRow()` / `previousRow()`
//   from arrow buttons.
// - `screens/StageLogScreen.kt` — reads `shotCount`, `rowCursor`,
//   and `dopeSnapshot`; calls `incrementShotCount()` after every
//   logged shot, `clearShotCount()` from the Clr button, and
//   `nextRow()` to advance DOPE after a shot.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure in-memory state holder — no I/O, no persistence.

package com.johnsondigital.loadout.wear.state

import com.johnsondigital.loadout.wear.bridge.ActiveLoadSnapshot
import com.johnsondigital.loadout.wear.bridge.DopeRow
import com.johnsondigital.loadout.wear.bridge.DopeSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-scoped singleton that holds the latest snapshots received
 * from the phone. The Wear OS Data Layer listener service runs in its
 * own process when the activity isn't open, so we expose the state via
 * a singleton that both the service AND the activity can write to /
 * read from.
 *
 * The activity collects `dopeSnapshot.collectAsState()` to drive the
 * UI; the listener writes via [setDope].
 *
 * `rowCursor` is the user's current scroll position in the DOPE
 * ladder. Persisted in-memory only (resets on cold launch).
 */
object WatchAppState {
    private val _dopeSnapshot = MutableStateFlow<DopeSnapshot?>(null)
    val dopeSnapshot: StateFlow<DopeSnapshot?> = _dopeSnapshot.asStateFlow()

    private val _activeLoad = MutableStateFlow<ActiveLoadSnapshot?>(null)
    val activeLoad: StateFlow<ActiveLoadSnapshot?> = _activeLoad.asStateFlow()

    private val _rowCursor = MutableStateFlow(0)
    val rowCursor: StateFlow<Int> = _rowCursor.asStateFlow()

    private val _shotCount = MutableStateFlow(0)
    val shotCount: StateFlow<Int> = _shotCount.asStateFlow()

    fun setDope(snap: DopeSnapshot) {
        _dopeSnapshot.value = snap
        if (_rowCursor.value >= snap.rows.size) {
            _rowCursor.value = (snap.rows.size - 1).coerceAtLeast(0)
        }
    }

    fun setActiveLoad(snap: ActiveLoadSnapshot) {
        _activeLoad.value = snap
    }

    fun nextRow() {
        val total = _dopeSnapshot.value?.rows?.size ?: return
        if (total == 0) return
        _rowCursor.value = (_rowCursor.value + 1).coerceAtMost(total - 1)
    }

    fun previousRow() {
        val total = _dopeSnapshot.value?.rows?.size ?: return
        if (total == 0) return
        _rowCursor.value = (_rowCursor.value - 1).coerceAtLeast(0)
    }

    fun currentRow(): DopeRow? {
        val rows = _dopeSnapshot.value?.rows ?: return null
        if (rows.isEmpty()) return null
        return rows.getOrNull(_rowCursor.value)
    }

    fun incrementShotCount() {
        _shotCount.value = _shotCount.value + 1
    }

    fun clearShotCount() {
        _shotCount.value = 0
    }
}
