// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/bridge/PhoneDataLayerListener.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Background service that receives Wear OS Data Layer events from the
// phone and routes them into [WatchAppState]. Subclasses
// `WearableListenerService`, the GMS-provided base that handles
// the `<service>` registration plumbing.
//
// Public surface:
//   * `class PhoneDataLayerListener : WearableListenerService()` — the
//     service. Wired up by the `<service>` element in the wear-module
//     `AndroidManifest.xml` with `<data android:pathPrefix="/loadout/" />`.
//   * `override fun onDataChanged(events: DataEventBuffer)` — handles
//     `DataItem` updates (the lossy DOPE / active_load / firearm_glance
//     paths).
//   * `override fun onMessageReceived(messageEvent: MessageEvent)` —
//     handles live `Message` events (timer_event, etc.).
//
// On every received payload, the service:
//   1. strips the `/loadout/` prefix from the path,
//   2. parses the JSON payload (silently dropping malformed payloads),
//   3. dispatches by short-path to one of the
//      `XxxSnapshot.fromJson` factories,
//   4. publishes into `WatchAppState`'s StateFlows.
//
// Unknown short-paths are intentionally ignored for forward-compat
// with phone versions newer than the watch's.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Wear OS apps often want to receive Data Layer events even when the
// UI isn't open (e.g. to wake up and update a complication). The
// `WearableListenerService` is the GMS pattern for that — Android
// starts the service when an event arrives even if the activity is
// closed. We wire it up with the `/loadout/` `pathPrefix` so the
// service receives ONLY our reserved paths and nothing else.
//
// (For Android newcomers: a `Service` is a backgrounded component
// distinct from an `Activity`. The OS can keep services running after
// the user dismisses the UI; `WearableListenerService` extends Service
// to add Data Layer dispatch. The `<service>` entry in
// `AndroidManifest.xml` is what tells Android "this class is a
// service" — without that registration, the OS ignores it.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **The service runs in its own process when the activity is closed.**
//    Wear OS's process model means `WatchAppState` can be touched
//    from the activity AND from this service in different processes.
//    BUT: when the activity IS open, both share the same process (the
//    listener service piggybacks on the activity's process), and the
//    StateFlow updates propagate to the UI immediately. When the
//    activity is closed, the service updates a separate
//    in-memory `WatchAppState` that gets discarded when the process
//    dies — this is fine because the next phone push will repopulate
//    it on demand. If we ever needed truly persistent state across
//    closed-app pushes, we'd write to disk here.
//
// 2. **`onDataChanged` only handles `TYPE_CHANGED`.** `DataEventBuffer`
//    can also surface `TYPE_DELETED`. The phone never deletes our
//    DataItems — only overwrites them — so we ignore the deleted
//    case. Adding handling for it (clearing the snapshot when the
//    phone deletes its DOPE) would be reasonable but isn't a
//    current requirement.
//
// 3. **`payloadStr` is null-safe.** A DataItem with our path but no
//    `payload` map key would be a phone bug. Skipping it (rather
//    than throwing) keeps the service alive and self-healing.
//
// 4. **The unknown-path branch is intentionally a no-op.** It's the
//    single most important forward-compatibility property of the
//    bridge — a future phone can send `firearm_glance` payloads
//    even if this version of the watch doesn't render them.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `android/wear/src/main/AndroidManifest.xml` — registers the
//   service with `<intent-filter>` actions
//   `com.google.android.gms.wearable.DATA_CHANGED` and
//   `com.google.android.gms.wearable.MESSAGE_RECEIVED`, scoped to
//   `pathPrefix="/loadout/"`.
// - `state/WatchAppState.kt` — receives parsed snapshots via
//   `setDope` and `setActiveLoad`.
// - `bridge/Payloads.kt` — `fromJson` factories.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Mutates `WatchAppState`'s StateFlows when valid payloads arrive.
// - Logs warnings for malformed JSON (dropped silently).
// - Does NOT make network calls. Wearable Data Layer is local
//   peer-to-peer transport per CLAUDE.md §13/§15.

package com.johnsondigital.loadout.wear.bridge

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import com.johnsondigital.loadout.wear.state.WatchAppState
import org.json.JSONException
import org.json.JSONObject

/**
 * Receives Data Layer events from the phone and routes them into
 * [WatchAppState]. Wired up by the `<service>` element in
 * `AndroidManifest.xml` with the `/loadout/` path prefix.
 *
 * This service runs in its own process when the watch UI isn't open,
 * which is why state is stored in a process-singleton (the activity
 * and service share the same process if the activity is open, so the
 * collected state propagates immediately).
 */
class PhoneDataLayerListener : WearableListenerService() {

    companion object {
        private const val TAG = "PhoneDataLayerListener"
    }

    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val item = event.dataItem
            val path = item.uri.path ?: continue
            if (!path.startsWith(WatchPaths.PATH_PREFIX)) continue
            val short = path.removePrefix(WatchPaths.PATH_PREFIX)
            val map = DataMapItem.fromDataItem(item).dataMap
            val payloadStr = map.getString("payload") ?: continue
            handlePayload(short, payloadStr)
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        if (!path.startsWith(WatchPaths.PATH_PREFIX)) return
        val short = path.removePrefix(WatchPaths.PATH_PREFIX)
        val payloadStr = String(messageEvent.data, Charsets.UTF_8)
        handlePayload(short, payloadStr)
    }

    private fun handlePayload(shortPath: String, payloadJson: String) {
        val obj = try {
            JSONObject(payloadJson)
        } catch (e: JSONException) {
            Log.w(TAG, "handlePayload: bad JSON for $shortPath: ${e.message}")
            return
        }
        when (shortPath) {
            WatchPaths.DOPE -> {
                DopeSnapshot.fromJson(obj)?.let(WatchAppState::setDope)
            }
            WatchPaths.ACTIVE_LOAD -> {
                ActiveLoadSnapshot.fromJson(obj)?.let(WatchAppState::setActiveLoad)
            }
            WatchPaths.FIREARM_GLANCE -> {
                // Reserved for future tab — not consumed yet.
            }
            else -> {
                // Unknown path — ignore. Keeps forward-compatibility
                // with future paths sent by newer phones.
            }
        }
    }
}
