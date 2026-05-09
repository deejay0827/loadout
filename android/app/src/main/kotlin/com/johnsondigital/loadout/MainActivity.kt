// FILE: android/app/src/main/kotlin/com/johnsondigital/loadout/MainActivity.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Phone-side `FlutterActivity` host for LoadOut on Android. The base
// class wires up the Flutter engine, surface, and lifecycle; this
// subclass exists solely to plumb the watch-companion bridge in
// `configureFlutterEngine` so the Dart `WatchBridgeService` has a
// MethodChannel/EventChannel pair to talk to as soon as the engine is
// up.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `WatchBridge` (the GMS Wearable Data Layer wrapper) needs the Flutter
// engine's binary messenger to register its channels. `configureFlutterEngine`
// is the canonical Flutter hook that fires once per engine, with the
// messenger ready, so this subclass is the right place to instantiate
// the bridge. `onDestroy` tears it down to release GMS listeners; without
// the teardown the activity would leak for the lifetime of the process.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - The OS (declared as the launch activity in `AndroidManifest.xml`).
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Constructs `WatchBridge`, which registers GMS Wearable listeners
//   (`MessageClient`, `DataClient`, `CapabilityClient`) and opens two
//   Flutter channels. All released in `onDestroy`.

package com.johnsondigital.loadout

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var watchBridge: WatchBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Idempotent — `configureFlutterEngine` only fires once per
        // engine, but a future Flutter SDK migration could re-fire it
        // (e.g. on background/foreground re-attach). The null-check
        // prevents double-registering GMS listeners.
        if (watchBridge == null) {
            watchBridge = WatchBridge(applicationContext, flutterEngine)
        }
    }

    override fun onDestroy() {
        watchBridge?.teardown()
        watchBridge = null
        super.onDestroy()
    }
}
