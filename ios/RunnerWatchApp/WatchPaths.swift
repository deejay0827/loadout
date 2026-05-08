// FILE: ios/RunnerWatchApp/WatchPaths.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// String constants for the reserved bridge paths shared between the
// watch app, the iPhone Runner, and the Flutter Dart side. Each path
// names one direction-tagged payload (DOPE, active load, firearm
// glance, shot log, timer event).
//
// Public surface:
//   * `enum WatchPaths` — five static let constants matching CLAUDE.md
//     §15: `activeLoad`, `dope`, `firearmGlance`, `logShot`,
//     `timerEvent`.
//   * `enum ShotSource` — three string constants the watch sets when
//     emitting `log_shot` (`motion`, `swipe`, `manual`).
//
// Both enums are value-only (no cases) — Swift's idiomatic way to
// namespace constants.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The watch bridge is implemented in three languages (Dart, Swift,
// Kotlin). All three have to use byte-identical strings on the wire,
// so each has its own copy of these constants. Having a dedicated
// file for them lets a future contributor see at a glance "here are
// the bridge paths" instead of hunting through DopeViewModel.swift or
// WatchConnectivityManager.swift.
//
// If this file disappeared, every consumer would inline string
// literals and the inevitable typo ("dop" instead of "dope") would
// silently drop messages on the floor.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Mirrors must stay in sync.** Three files (this one,
//    `lib/models/watch_payloads.dart`, and the Wear OS
//    `bridge/WatchPaths.kt`) declare the SAME strings. Adding a new
//    path means touching all three; renaming an existing one breaks
//    every running build of every paired phone. If you change anything
//    here, grep the other two files immediately.
//
// 2. **`enum` with no cases, by Swift convention.** Declaring this
//    as `enum` rather than `struct` makes it impossible to instantiate
//    accidentally. The ergonomics are identical (`WatchPaths.dope`)
//    but the compiler refuses `WatchPaths()`.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - ios/RunnerWatchApp/WatchConnectivityManager.swift — uses
//   `WatchPaths.logShot` etc. when sending and dispatching.
// - ios/RunnerWatchApp/WatchAppDelegate.swift — references
//   `WatchPaths.logShot` and `WatchPaths.timerEvent` when bridging
//   the per-feature senders.
// - ios/RunnerWatchApp/DopeViewModel.swift — switches on
//   `WatchPaths.dope` / `.activeLoad` / `.firearmGlance` to decode
//   incoming payloads.
// - ios/RunnerWatchApp/StageLogView.swift — uses `ShotSource.motion`,
//   `.swipe`, `.manual` when logging.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure constants.

import Foundation

enum WatchPaths {
    static let activeLoad = "active_load"
    static let dope = "dope"
    static let firearmGlance = "firearm_glance"
    static let logShot = "log_shot"
    static let timerEvent = "timer_event"
}

enum ShotSource {
    static let motion = "motion"
    static let swipe = "swipe"
    static let manual = "manual"
}
