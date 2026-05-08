// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/bridge/Payloads.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Kotlin data classes for the typed payloads received from the iPhone
// over the Wear OS Data Layer. Each class pairs a Kotlin shape with a
// `companion object fromJson(...)` factory so the listener service can
// decode incoming JSON-blobs without unsafe `as` casts.
//
// Public surface:
//   * `data class DopeRow` — one row of the DOPE ladder (range, drop,
//     wind, velocity, time-of-flight). Wire keys: `r/u/w/v/t`.
//   * `data class DopeSnapshot` — header + N rows of the ballistic
//     solution. Wire keys: `cart`, `bgr`, `bn`, `mv`, `z`, `ws`, `wd`,
//     `dm`, `bc`, `pn` (optional), `fn` (optional), `g`, `rows`.
//   * `data class ActiveLoadSnapshot` — current recipe summary. Wire
//     keys: `n` (name), `cart` (cartridge), `p` (powder), `pgr` (powder
//     grains), `b` (bullet), `bgr` (bullet grains).
//
// Each `fromJson` returns null on any decode failure rather than
// throwing — the listener treats null as "ignore this payload" and
// keeps polling.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Wear OS DataItems carry raw JSON-string payloads under the `payload`
// key of the `DataMap`. The listener service receives them as `String`,
// parses with `JSONObject`, and hands the parsed object to one of the
// `fromJson` factories. Without these classes, every screen would do
// its own `getDouble("u")` boilerplate and silently drift out of sync
// with the iPhone-side senders.
//
// The data classes mirror their Swift cousins (`DopeRow`, `DopeSnapshot`,
// `ActiveLoadSnapshot` in `ios/RunnerWatchApp/DopeViewModel.swift`)
// and the Dart canonical (`lib/models/watch_payloads.dart`). All three
// must stay in sync; renaming a key here without renaming on the other
// two layers silently drops the field.
//
// (For Kotlin newcomers: `data class` auto-generates `equals`,
// `hashCode`, `toString`, and `copy` — perfect for value objects that
// flow through StateFlows. The `companion object` is Kotlin's idiom
// for "static methods on this class"; `DopeRow.fromJson(...)` reads
// like Java's `static DopeRow fromJson(...)`.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Single-letter JSON keys are deliberate.** The Data Layer caps
//    individual `DataItem` payloads at ~16 KB. A 15-row DOPE ladder
//    with single-letter keys serialises to ~700 bytes; with verbose
//    keys (rangeYd, dropMil, etc.) it would be 2–3x bigger and we'd
//    hit the cap on long-range tables. Don't rename keys for
//    "readability" without recalculating the budget. The Dart
//    encoder is the source of truth for which letters mean what.
//
// 2. **`optString("pn", null.toString()).takeIf { ... != "null" }` is
//    a workaround for `org.json`.** `JSONObject.optString(key, null)`
//    returns the literal string "null" rather than a Kotlin null when
//    a key is absent — a long-standing org.json quirk. The
//    `.takeIf { it.isNotEmpty() && it != "null" }` chain converts back
//    to Kotlin null. Look unnecessary, isn't.
//
// 3. **`fromJson` returns null on ANY error, including missing keys.**
//    A partially-malformed payload from a future phone version
//    shouldn't crash the watch — silently dropping it (and continuing
//    to display the previous valid payload) is the right failure
//    mode. The listener treats `null` as "skip" and keeps the prior
//    state.
//
// 4. **Optional fields are decoded with `.has(key)` checks.** The
//    iOS / Dart encoders omit absent optional fields entirely (no
//    `null` encoding). `obj.optDouble("pgr")` would return 0.0 for
//    a missing key, which would silently corrupt the model. Always
//    `if (obj.has("pgr"))` before reading.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `bridge/PhoneDataLayerListener.kt` — calls `DopeSnapshot.fromJson(obj)`
//   and `ActiveLoadSnapshot.fromJson(obj)` on every received payload.
// - `state/WatchAppState.kt` — stores parsed snapshots in StateFlows.
// - `screens/DopeScreen.kt` — reads `DopeSnapshot` + `DopeRow` for
//   rendering.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure data classes + decoders. No I/O.

package com.johnsondigital.loadout.wear.bridge

import org.json.JSONException
import org.json.JSONObject

/**
 * One row of a downrange ballistic solution. Mirrors `DopeRow` in the
 * other two layers. Uses single-letter keys to fit comfortably in the
 * 16 KB Data Layer payload budget.
 */
data class DopeRow(
    val rangeYd: Int,
    val dropMil: Double,
    val windMil: Double,
    val velocityFps: Double,
    val timeOfFlightSec: Double,
) {
    companion object {
        fun fromJson(obj: JSONObject): DopeRow? {
            return try {
                DopeRow(
                    rangeYd = obj.getInt("r"),
                    dropMil = obj.getDouble("u"),
                    windMil = obj.getDouble("w"),
                    velocityFps = obj.getDouble("v"),
                    timeOfFlightSec = obj.getDouble("t"),
                )
            } catch (e: JSONException) {
                null
            }
        }
    }
}

/**
 * Compact ballistic snapshot pushed from the phone. Stays under the
 * Data Layer 16 KB budget by using single-letter keys and rounded
 * mil values.
 */
data class DopeSnapshot(
    val cartridgeName: String,
    val bulletGr: Double,
    val bulletName: String,
    val muzzleVelocityFps: Double,
    val zeroRangeYd: Int,
    val windSpeedMph: Double,
    val windFromDeg: Double,
    val dragModel: String,
    val bc: Double,
    val profileName: String?,
    val firearmName: String?,
    val generatedAtMs: Long,
    val rows: List<DopeRow>,
) {
    companion object {
        fun fromJson(obj: JSONObject): DopeSnapshot? {
            return try {
                val rowsArr = obj.getJSONArray("rows")
                val rows = mutableListOf<DopeRow>()
                for (i in 0 until rowsArr.length()) {
                    DopeRow.fromJson(rowsArr.getJSONObject(i))?.let(rows::add)
                }
                DopeSnapshot(
                    cartridgeName = obj.getString("cart"),
                    bulletGr = obj.getDouble("bgr"),
                    bulletName = obj.getString("bn"),
                    muzzleVelocityFps = obj.getDouble("mv"),
                    zeroRangeYd = obj.getInt("z"),
                    windSpeedMph = obj.optDouble("ws", 0.0),
                    windFromDeg = obj.optDouble("wd", 0.0),
                    dragModel = obj.getString("dm"),
                    bc = obj.getDouble("bc"),
                    profileName = obj.optString("pn", null.toString()).takeIf { it.isNotEmpty() && it != "null" },
                    firearmName = obj.optString("fn", null.toString()).takeIf { it.isNotEmpty() && it != "null" },
                    generatedAtMs = obj.optLong("g", System.currentTimeMillis()),
                    rows = rows,
                )
            } catch (e: JSONException) {
                null
            }
        }
    }
}

/** Active recipe summary pushed to the watch. */
data class ActiveLoadSnapshot(
    val name: String,
    val cartridgeName: String,
    val powderName: String? = null,
    val powderChargeGr: Double? = null,
    val bulletName: String? = null,
    val bulletWeightGr: Double? = null,
) {
    companion object {
        fun fromJson(obj: JSONObject): ActiveLoadSnapshot? {
            return try {
                ActiveLoadSnapshot(
                    name = obj.getString("n"),
                    cartridgeName = obj.getString("cart"),
                    powderName = obj.optString("p", "").ifEmpty { null },
                    powderChargeGr = if (obj.has("pgr")) obj.optDouble("pgr") else null,
                    bulletName = obj.optString("b", "").ifEmpty { null },
                    bulletWeightGr = if (obj.has("bgr")) obj.optDouble("bgr") else null,
                )
            } catch (e: JSONException) {
                null
            }
        }
    }
}
