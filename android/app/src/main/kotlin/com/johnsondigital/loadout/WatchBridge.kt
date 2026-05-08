// FILE: android/app/src/main/kotlin/com/johnsondigital/loadout/WatchBridge.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Phone-side wrapper around the Wearable Data Layer for the LoadOut
// Wear OS companion. Mirrors `ios/Runner/WatchSessionBridge.swift` —
// same channel names, same wire format — so the Dart
// `WatchBridgeService` is platform agnostic.
//
// Public surface:
//   * `class WatchBridge(Context, FlutterEngine)` — instantiated once
//     in `MainActivity.configureFlutterEngine`.
//   * `companion object` constants:
//     - `METHOD_CHANNEL = "loadout/watch_bridge"` — must match Dart
//       and iOS.
//     - `EVENT_CHANNEL = "loadout/watch_bridge/events"` — same.
//     - `PATH_PREFIX = "/loadout/"` — every reserved short-path is
//       written to the wire as `/loadout/<short>` (Wear OS Data
//       Layer convention).
//     - `CAPABILITY = "loadout_watch_companion"` — the watch
//       advertises this capability so the phone can target only
//       reachable nodes that have the app installed.
//   * `fun register()` — kept for symmetry with iOS; init does the
//     real work.
//   * `fun teardown()` — releases listeners; called from
//     `MainActivity.onDestroy`.
//
// Implements three GMS callbacks: `MessageClient.OnMessageReceivedListener`,
// `DataClient.OnDataChangedListener`, `CapabilityClient.OnCapabilityChangedListener`.
//
// MethodChannel methods (callable from Dart):
//   * `isWatchPaired` → Bool (any connected node)
//   * `isWatchAppInstalled` → Bool (any node with our capability)
//   * `isReachable` → Bool (any reachable node with our capability)
//   * `send` with `{path, payload, lossy}` — routes to either a
//     DataItem (lossy) or a Message (live).
//
// Reserved paths (CLAUDE.md §15):
//   /loadout/active_load     phone → watch     DataItem (lossy)
//   /loadout/dope            phone → watch     DataItem (lossy)
//   /loadout/firearm_glance  phone → watch     DataItem (lossy)
//   /loadout/log_shot        watch → phone     Message (queued)
//   /loadout/timer_event     watch ↔ phone     Message (live)
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Flutter has no Wear OS support; the watch app is a separate native
// `:wear` Gradle module. The two halves communicate via Google Play
// Services' Wearable Data Layer. This file is the phone-side bridge —
// it owns the GMS clients, exposes a MethodChannel/EventChannel pair
// to Dart, and translates Flutter's `Map<String, Any>` arguments
// into the right Wear OS transport (DataItem vs Message).
//
// Without this file, Dart payloads couldn't reach the watch at all —
// every send would silently no-op. The matching iOS file is
// `WatchSessionBridge.swift`; the two share channel names so Dart
// code is platform-agnostic.
//
// (For Android newcomers: the Wearable Data Layer is the only
// sanctioned channel between an Android phone and its paired Wear OS
// watch. `DataClient.putDataItem(...)` writes a single canonical
// payload at a stable URI — newer puts overwrite older ones, which
// is why DOPE works perfectly with it. `MessageClient.sendMessage(...)`
// is fire-and-forget and only delivers if the target node is
// reachable.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Two transport types with different lossiness semantics.**
//    `DataClient.putDataItem(...)` is the lossy path — only the
//    LATEST payload at a given URI is delivered, even when the
//    watch wakes from sleep. Perfect for DOPE / active load.
//    `MessageClient.sendMessage(...)` is the live path — sends
//    fire-and-forget to every reachable node, with no queueing.
//    The wrong choice silently breaks features: a queued log_shot
//    (which we send via `messageClient` watch→phone) would arrive
//    only when the phone was foreground; the queued case is handled
//    by the watch falling back to DataItem if message fails.
//
// 2. **Capability filtering matters.** `CAPABILITY` is the
//    watch-advertised marker that says "I'm a LoadOut watch." Without
//    it, sends would target every Wear OS device the user has paired
//    (a Google watch, a Galaxy watch, a fitness tracker), most of
//    which would have no LoadOut app to receive the payload.
//
// 3. **Listener lifecycle is critical.** GMS clients hold strong
//    references to listeners through internal binders. NOT
//    unregistering in `teardown` would leak the activity for the
//    duration of the process. Always remove every listener you
//    added.
//
// 4. **Sends run on a single-thread executor.** The GMS client
//    methods are blocking (`Tasks.await`); calling them on the main
//    thread freezes the UI. `sendExecutor` is a single-thread
//    executor so per-payload sends serialise (preventing race
//    conditions on stable URIs) and never block the UI thread.
//
// 5. **`org.json` vs Map<String, Any?>.** Flutter delivers
//    `Map<String, Any?>` from Dart; the Wear OS Data Layer
//    `DataMap` doesn't accept arbitrary maps. We round-trip through
//    `JSONObject` because that's what both sides can parse. Adding
//    a new payload type means making sure every value coerces to a
//    JSON-friendly primitive (Number, String, Bool, List, Map).
//    `jsonValue(...)` falls back to `value.toString()` for unknown
//    types, which is forgiving but a sign you should add an explicit
//    branch.
//
// 6. **`emitConnectionState` chains two queries.** Determining the
//    actual state requires asking GMS twice: "is anything paired?"
//    and "is the watch app installed AND reachable?". The second
//    query depends on the first, so we chain callbacks rather than
//    parallelising. Race-conditioning the two would mis-classify
//    `notPaired` as `notReachable` on first launch.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `MainActivity.kt` — instantiates and registers / tears down.
// - `lib/services/watch_bridge_service.dart` — the Dart side of
//   this bridge. Channel names + the `path/payload/lossy` argument
//   shape must stay in sync.
// - Peer: `ios/Runner/WatchSessionBridge.swift` — iOS counterpart
//   with identical surface from Dart's perspective.
// - The watch-side counterpart is `android/wear/.../bridge/PhoneDataLayerListener.kt`
//   and `PhoneDataLayerSender.kt`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Registers with GMS Wearable's MessageClient, DataClient, and
//   CapabilityClient. Releases all three on teardown.
// - Opens MethodChannel + EventChannel on the Flutter engine's
//   binary messenger.
// - Writes DataItems to and reads from the Wearable Data Layer (a
//   peer-to-peer Bluetooth/Wi-Fi transport). No HTTP, no Firebase,
//   no analytics — privacy contract from CLAUDE.md §13/§15.

package com.johnsondigital.loadout

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Phone-side wrapper around the Wearable Data Layer for the LoadOut Wear OS
 * companion. Mirrors the iOS [WatchSessionBridge] surface — same channel
 * names, same wire format — so the Dart `WatchBridgeService` is platform
 * agnostic.
 *
 * Reserved paths (CLAUDE.md §15):
 *
 *   /loadout/active_load     phone -> watch     DataItem (lossy)
 *   /loadout/dope            phone -> watch     DataItem (lossy)
 *   /loadout/firearm_glance  phone -> watch     DataItem (lossy)
 *   /loadout/log_shot        watch -> phone     Message (queued)
 *   /loadout/timer_event     watch <-> phone    Message (live)
 *
 * Privacy: this class makes no network calls. All transport is the
 * Google Play Services Wearable Data Layer (encrypted peer-to-peer).
 *
 * Wire-up: [register] is called from `MainActivity.configureFlutterEngine`.
 */
class WatchBridge(
    private val context: Context,
    flutterEngine: FlutterEngine,
) : MessageClient.OnMessageReceivedListener,
    DataClient.OnDataChangedListener,
    CapabilityClient.OnCapabilityChangedListener {

    companion object {
        private const val TAG = "WatchBridge"
        const val METHOD_CHANNEL = "loadout/watch_bridge"
        const val EVENT_CHANNEL = "loadout/watch_bridge/events"
        private const val PATH_PREFIX = "/loadout/"
        private const val CAPABILITY = "loadout_watch_companion"
    }

    private val messageClient: MessageClient = Wearable.getMessageClient(context)
    private val dataClient: DataClient = Wearable.getDataClient(context)
    private val capabilityClient: CapabilityClient = Wearable.getCapabilityClient(context)

    private val sendExecutor = Executors.newSingleThreadExecutor()

    private val methodChannel: MethodChannel =
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val eventChannel: EventChannel =
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)

    private var eventSink: EventChannel.EventSink? = null

    init {
        methodChannel.setMethodCallHandler(::onMethodCall)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
                emitConnectionState()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        messageClient.addListener(this)
        dataClient.addListener(this)
        capabilityClient.addListener(this, CAPABILITY)
    }

    fun register() {
        // No-op: registration happens in init. Kept for symmetry with the
        // iOS bridge's `activate(with:)` entry point.
    }

    fun teardown() {
        messageClient.removeListener(this)
        dataClient.removeListener(this)
        capabilityClient.removeListener(this)
        sendExecutor.shutdown()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isWatchPaired" -> {
                queryNodes(reachableOnly = false) { nodes ->
                    result.success(nodes.isNotEmpty())
                }
            }
            "isWatchAppInstalled" -> {
                queryCapabilityNodes { nodes ->
                    result.success(nodes.isNotEmpty())
                }
            }
            "isReachable" -> {
                queryCapabilityNodes(reachableOnly = true) { nodes ->
                    result.success(nodes.isNotEmpty())
                }
            }
            "send" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("BAD_ARGS", "send() expects a map", null)
                    return
                }
                val path = args["path"] as? String
                @Suppress("UNCHECKED_CAST")
                val payload = args["payload"] as? Map<String, Any?>
                val lossy = (args["lossy"] as? Boolean) ?: false
                if (path == null || payload == null) {
                    result.error("BAD_ARGS", "send() expects {path, payload, lossy}", null)
                    return
                }
                send(path, payload, lossy)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun send(path: String, payload: Map<String, Any?>, lossy: Boolean) {
        val fullPath = PATH_PREFIX + path
        val json = mapToJson(payload).toString()

        sendExecutor.submit {
            try {
                if (lossy) {
                    // Lossy DataItem — single canonical row at this path,
                    // overwrites in place. Watch wakes to the latest snapshot.
                    val request = PutDataMapRequest.create(fullPath).apply {
                        dataMap.putString("payload", json)
                        dataMap.putLong("ts", System.currentTimeMillis())
                    }
                    val req = request.asPutDataRequest().setUrgent()
                    Tasks.await(dataClient.putDataItem(req))
                } else {
                    // Live message — sent to every reachable node with the
                    // companion installed. Falls back silently if no nodes
                    // are connected; the watch's queued DataItems still
                    // pick up the latest state when it next wakes.
                    val nodes = Tasks.await(
                        capabilityClient.getCapability(CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                    ).nodes
                    val payloadBytes = json.toByteArray(Charsets.UTF_8)
                    for (node in nodes) {
                        Tasks.await(messageClient.sendMessage(node.id, fullPath, payloadBytes))
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "send($path) failed: ${t.message}")
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        if (!path.startsWith(PATH_PREFIX)) return
        val short = path.removePrefix(PATH_PREFIX)
        val json = String(messageEvent.data, Charsets.UTF_8)
        forwardToFlutter(short, json)
    }

    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val item = event.dataItem
            val path = item.uri.path ?: continue
            if (!path.startsWith(PATH_PREFIX)) continue
            val short = path.removePrefix(PATH_PREFIX)
            val map = DataMapItem.fromDataItem(item).dataMap
            val json = map.getString("payload") ?: continue
            forwardToFlutter(short, json)
        }
    }

    override fun onCapabilityChanged(p0: com.google.android.gms.wearable.CapabilityInfo) {
        emitConnectionState()
    }

    private fun forwardToFlutter(path: String, json: String) {
        val payload: Map<String, Any?> = try {
            jsonToMap(JSONObject(json))
        } catch (e: JSONException) {
            Log.w(TAG, "forwardToFlutter: bad JSON for $path: ${e.message}")
            return
        }
        val event: Map<String, Any?> = mapOf(
            "path" to path,
            "payload" to payload,
        )
        val sink = eventSink ?: return
        // Sinks must be invoked on the main looper.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            sink.success(event)
        }
    }

    private fun emitConnectionState() {
        queryCapabilityNodes(reachableOnly = false) { allNodes ->
            if (allNodes.isEmpty()) {
                emitState("notPaired")
                return@queryCapabilityNodes
            }
            queryCapabilityNodes(reachableOnly = true) { reachable ->
                if (reachable.isEmpty()) {
                    emitState(if (allNodes.isEmpty()) "appNotInstalled" else "notReachable")
                } else {
                    emitState("reachable")
                }
            }
        }
    }

    private fun emitState(state: String) {
        val sink = eventSink ?: return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            sink.success(mapOf("state" to state))
        }
    }

    private fun queryNodes(
        reachableOnly: Boolean,
        callback: (List<Node>) -> Unit,
    ) {
        val task = Wearable.getNodeClient(context).connectedNodes
        task.addOnSuccessListener { nodes ->
            val filtered = if (reachableOnly) nodes.filter { it.isNearby } else nodes
            callback(filtered)
        }.addOnFailureListener {
            callback(emptyList())
        }
    }

    private fun queryCapabilityNodes(
        reachableOnly: Boolean = false,
        callback: (Set<Node>) -> Unit,
    ) {
        val filter = if (reachableOnly) {
            CapabilityClient.FILTER_REACHABLE
        } else {
            CapabilityClient.FILTER_ALL
        }
        capabilityClient.getCapability(CAPABILITY, filter)
            .addOnSuccessListener { info ->
                callback(info.nodes)
            }
            .addOnFailureListener {
                callback(emptySet())
            }
    }

    private fun mapToJson(map: Map<String, Any?>): JSONObject {
        val obj = JSONObject()
        for ((key, value) in map) {
            obj.put(key, jsonValue(value))
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
            is Number, is String, is Boolean -> value
            else -> value.toString()
        }
    }

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = unwrapJson(obj.get(key))
        }
        return out
    }

    private fun unwrapJson(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonToMap(value)
            is org.json.JSONArray -> {
                val list = mutableListOf<Any?>()
                for (i in 0 until value.length()) list.add(unwrapJson(value.get(i)))
                list
            }
            else -> value
        }
    }
}
