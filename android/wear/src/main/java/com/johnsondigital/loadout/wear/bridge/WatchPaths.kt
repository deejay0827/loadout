// FILE: android/wear/src/main/java/com/johnsondigital/loadout/wear/bridge/WatchPaths.kt
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// String constants for the reserved bridge paths shared between the
// watch app, the phone-side `WatchBridge`, and the Dart side.
// Each path names one direction-tagged payload (DOPE, active load,
// firearm glance, shot log, timer event).
//
// Public surface:
//   * `object WatchPaths` — six values:
//     - `PATH_PREFIX = "/loadout/"` — the Wear OS Data Layer path
//       convention. Every reserved short-path is written to the wire
//       as `/loadout/<short>`.
//     - `ACTIVE_LOAD`, `DOPE`, `FIREARM_GLANCE`, `LOG_SHOT`,
//       `TIMER_EVENT` — the short-path constants matching CLAUDE.md
//       §15.
//   * `fun fullPath(shortPath: String): String` — convenience that
//     concatenates `PATH_PREFIX + shortPath`.
//   * `object ShotSource` — three constants the watch sets when
//     emitting `log_shot`: `MOTION`, `SWIPE`, `MANUAL`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The watch bridge is implemented in three languages (Dart, Swift,
// Kotlin). All three have to use byte-identical strings on the wire,
// so each has its own copy of these constants. Having a dedicated
// file for them lets a future contributor see at a glance "here are
// the bridge paths" instead of hunting through screens or the listener
// service.
//
// (For Kotlin newcomers: top-level `object` declares a singleton — the
// Kotlin equivalent of a Java `final class` with a private constructor
// and `static` members. Reading `WatchPaths.DOPE` is direct property
// access; there's no instance to allocate.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Three mirror files must stay in sync.** Adding a new path means
//    touching:
//      - `lib/models/watch_payloads.dart` (Dart side)
//      - `ios/RunnerWatchApp/WatchPaths.swift` (iOS side)
//      - this file (Wear OS side)
//      - and the phone-side `WatchBridge.kt` if the path needs new
//        routing.
//    Renaming an existing path breaks every running build of every
//    paired phone — the wire is unversioned.
//
// 2. **Wear OS uses `/loadout/<path>`; iOS doesn't.** Apple's
//    WatchConnectivity uses an envelope `{path, payload}` and treats
//    `path` as application-level metadata. Wear OS's Data Layer uses
//    a URI path. We unify by always making Dart talk in short-path
//    form (`dope`, not `/loadout/dope`); the Wear OS bridge prepends
//    the prefix on send and strips it on receive. iOS sees the
//    short-path raw.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `bridge/PhoneDataLayerListener.kt` — switches on the short-path
//   to dispatch incoming payloads.
// - `bridge/PhoneDataLayerSender.kt` — calls `WatchPaths.fullPath(...)`
//   when constructing the URI for outbound messages.
// - `screens/StageLogScreen.kt` — uses `WatchPaths.LOG_SHOT` and
//   `ShotSource.MOTION/SWIPE/MANUAL` when sending shot logs.
// - `timer/TimerEngine.kt` — uses `WatchPaths.TIMER_EVENT` when
//   emitting timer events.
//
// This file ships on a separate Gradle sub-project (`:wear`), not in
// the main `:app` module.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure constants + a string concatenation helper.

package com.johnsondigital.loadout.wear.bridge

/**
 * Reserved bridge paths. Match CLAUDE.md §15 verbatim. Mirrors the
 * iOS `WatchPaths.swift` and the Dart `lib/models/watch_payloads.dart`
 * so all three layers use the same wire-format keys.
 *
 * Wear OS Data Layer convention is `/<app>/<short-path>`, so we prefix
 * every reserved short-path with `/loadout/` when writing to the Data
 * Layer. The phone-side bridge applies the same prefix on iOS-side
 * too (via the WatchSessionBridge envelope), but iOS doesn't actually
 * use a path prefix on the wire — only the Data Layer does.
 */
object WatchPaths {
    const val PATH_PREFIX = "/loadout/"

    // Short paths (the wire form is `${PATH_PREFIX}${shortPath}`).
    const val ACTIVE_LOAD = "active_load"
    const val DOPE = "dope"
    const val FIREARM_GLANCE = "firearm_glance"
    const val LOG_SHOT = "log_shot"
    const val TIMER_EVENT = "timer_event"

    fun fullPath(shortPath: String): String = PATH_PREFIX + shortPath
}

/**
 * Sources reported when logging a shot. Mirrors `ShotSource` on the
 * other two layers. The phone enumerates these for filtering but
 * trusts the watch to send a valid value.
 */
object ShotSource {
    const val MOTION = "motion"
    const val SWIPE = "swipe"
    const val MANUAL = "manual"
}
