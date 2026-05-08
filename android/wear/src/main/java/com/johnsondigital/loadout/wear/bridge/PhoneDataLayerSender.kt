// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/bridge/PhoneDataLayerSender.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Watch → phone sender for the LoadOut Wear OS companion. Wraps the
// Wearable Data Layer's `MessageClient` and only sends to nodes that
// advertise the `loadout_phone_companion` capability.
//
// Public surface:
//   * `class PhoneDataLayerSender(Context)` — instantiated once in
//     `MainActivity.onCreate`.
//   * `fun send(shortPath: String, payload: Map<String, Any?>)` —
//     serialises the payload to JSON and dispatches a Message to
//     every reachable phone node. Path is the short form (e.g.
//     `log_shot`); the sender prepends `/loadout/`.
//   * `fun shutdown()` — releases the single-thread executor.
//     Called from `MainActivity.onDestroy`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Watch-originated messages (shot logs, timer ticks) need a single,
// well-tested path to the phone. Pulling the GMS plumbing into this
// class means screens / view-models can call
// `sender.send(WatchPaths.LOG_SHOT, payload)` without knowing
// anything about MessageClient, CapabilityClient, or threading.
//
// Splitting the watch->phone direction (this file) from the
// phone->watch direction (`PhoneDataLayerListener`) mirrors the
// asymmetry of the Wear OS API: the listener service is what GMS
// wakes when a payload lands, but for sending we want an explicit
// `MessageClient` reference held for the lifetime of the activity.
//
// (For Android newcomers: GMS clients like `MessageClient` are
// reference-counted handles — calling `Wearable.getMessageClient(ctx)`
// is cheap if you've already done it once. We cache the handle on
// construction so every `send` call uses the same client.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Single-thread executor for blocking GMS calls.** Both
//    `capabilityClient.getCapability(...)` and
//    `messageClient.sendMessage(...)` return `Task<T>`. We use
//    `Tasks.await(...)` to make them synchronous, which would block
//    the calling thread. Submitting on a single-thread executor (a)
//    keeps the UI thread responsive and (b) serialises sends so two
//    near-simultaneous logs don't race against each other.
//
// 2. **Targeting `loadout_phone_companion` capability.** Without the
//    capability filter, `sendMessage` would try to deliver to every
//    Wear OS node the user has paired (a fitness tracker, a
//    different LoadOut watch, etc.). Filtering ensures the message
//    only goes to the LoadOut phone app, which prevents "watch
//    sends shot log to fitness tracker that throws ENOSUPPORT" log
//    spam.
//
// 3. **Failures are logged, not surfaced.** `try/catch (Throwable)`
//    is broad-on-purpose — Wear OS connection failures are common
//    (Bluetooth flaps, phone in airplane mode) and we don't want
//    every flap to pop a UI error. The watch's UI optimistically
//    increments the shot count locally, and if the message fails
//    the user can re-sync from the phone-side range day on next
//    open.
//
// 4. **`mapToJson` accepts arbitrary Map<String, Any?>.** The
//    fallback `value.toString()` for unknown types is permissive —
//    forgiving for typos but be aware: passing a `LocalDate` will
//    serialise as `"2026-05-08"`, not `1715126400000`. Always pass
//    primitives.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — instantiates and shuts down.
// - `screens/StageLogScreen.kt` — calls `send(WatchPaths.LOG_SHOT, ...)`
//   from each of motion / swipe / manual log paths.
// - `timer/TimerEngine.kt` — calls `send(WatchPaths.TIMER_EVENT, ...)`
//   on every timer state transition (best-effort phone mirror).
// - The peer is `android/app/.../WatchBridge.kt` on the phone, which
//   listens for these incoming Messages.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Submits sends on a single-thread `Executors.newSingleThreadExecutor()`.
//   Each send blocks the executor on Tasks.await for ~ms (Bluetooth
//   round trip).
// - Calls GMS Wearable's `MessageClient.sendMessage` — peer-to-peer
//   Bluetooth transport, no HTTP, no analytics. Privacy contract
//   from CLAUDE.md §13/§15.

package com.johnsondigital.loadout.wear.bridge

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Watch -> phone sender. Wraps the Wearable Data Layer's
 * [MessageClient] and only ever sends to nodes that advertise the
 * `loadout_phone_companion` capability.
 *
 * Used by:
 *   - ShotLogger      sends `/loadout/log_shot`
 *   - TimerScreen     sends `/loadout/timer_event` (optional)
 *
 * Privacy: no HTTP. All transport is the Wearable Data Layer.
 * See CLAUDE.md §15.
 */
class PhoneDataLayerSender(private val appContext: Context) {

    companion object {
        private const val TAG = "PhoneDataLayerSender"
        private const val PHONE_CAPABILITY = "loadout_phone_companion"
    }

    private val messageClient: MessageClient = Wearable.getMessageClient(appContext)
    private val capabilityClient: CapabilityClient =
        Wearable.getCapabilityClient(appContext)
    private val sendExecutor = Executors.newSingleThreadExecutor()

    fun send(shortPath: String, payload: Map<String, Any?>) {
        val fullPath = WatchPaths.fullPath(shortPath)
        val json = mapToJson(payload).toString()
        sendExecutor.submit {
            try {
                val info = Tasks.await(
                    capabilityClient.getCapability(
                        PHONE_CAPABILITY,
                        CapabilityClient.FILTER_REACHABLE
                    )
                )
                val nodes = info.nodes
                if (nodes.isEmpty()) {
                    Log.d(TAG, "send($shortPath): no reachable phone nodes")
                    return@submit
                }
                val bytes = json.toByteArray(Charsets.UTF_8)
                for (node in nodes) {
                    Tasks.await(messageClient.sendMessage(node.id, fullPath, bytes))
                }
            } catch (t: Throwable) {
                Log.w(TAG, "send($shortPath) failed: ${t.message}")
            }
        }
    }

    fun shutdown() {
        sendExecutor.shutdown()
    }

    private fun mapToJson(map: Map<String, Any?>): JSONObject {
        val obj = JSONObject()
        for ((k, v) in map) {
            obj.put(k, jsonValue(v))
        }
        return obj
    }

    private fun jsonValue(value: Any?): Any? {
        return when (value) {
            null -> JSONObject.NULL
            is Map<*, *> -> {
                @Suppress("UNCHECKED_CAST")
                mapToJson(value as Map<String, Any?>)
            }
            is List<*> -> {
                val arr = org.json.JSONArray()
                for (item in value) arr.put(jsonValue(item))
                arr
            }
            else -> value
        }
    }
}
