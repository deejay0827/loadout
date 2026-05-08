// FILE: ios/RunnerWatchApp/ShotLogger.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Per-session shot tally + forwarder. Owns three `@Published`
// properties (`shotCount`, `lastSource`, `lastAt`) that the Stage Log
// view reads, and exposes `log(source:peakG:rangeYd:)` which:
//   1. builds a `log_shot` payload (epoch ms timestamp + source +
//      optional `r` (range yards) and `g` (peak g)),
//   2. forwards it via the `send` closure (bound by the app delegate
//      to `WatchConnectivityManager.send`),
//   3. increments the local counter,
//   4. plays a confirmation `.click` haptic.
//
// `clear()` resets the count for a new stage / range trip.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Centralising the "log a shot" path here means motion-detected,
// swipe-detected, and manual-tap shots all funnel through a single
// method that emits the same wire format and applies the same
// haptic. Without this file, each entry point in `StageLogView`
// would format its own payload and the haptic would either fire 3x
// (one per code path) or not at all.
//
// The closure-based `send` indirection also means `ShotLogger` is
// trivially mockable in tests — set `logger.send = { capturedPayload
// = $0 }` and assert against the captured value.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Shot count is intentionally NOT persisted.** It represents
//    the active stage or range-day session — when the user taps
//    "Clear" on Stage Log, the count goes to zero. If we persisted
//    it, the user would launch the app the next morning and see
//    yesterday's count, which is misleading. The phone-side range
//    day repository is the source of truth for historical counts.
//
// 2. **Haptic fires AFTER the send is queued.** The `.click` haptic
//    is the user's confirmation that the log went through. We fire
//    it immediately after `send?(payload)` because the queued send
//    almost always succeeds; the alternative (waiting for an ack)
//    would either delay the feedback by a network round-trip or
//    require unwiring the bridge to support callbacks.
//
// 3. **Compact JSON keys mirror `lib/models/watch_payloads.dart`.**
//    `at` (timestamp), `src` (source), `r` (range yards), `g` (peak
//    g) — all single-letter to fit the 16 KiB envelope budget. The
//    iPhone-side decoder expects exactly these keys.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `StageLogView.swift` — calls `log(source:peakG:rangeYd:)` from
//   each of the three input paths and `clear()` from the settings
//   sheet's "Clear shot count" button.
// - `WatchAppDelegate.swift` — instantiates and binds `send` to
//   `WatchConnectivityManager.send(path: WatchPaths.logShot, ...)`.
// - `LoadOutWatchApp.swift` — injects into the SwiftUI environment
//   so any view can observe.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Plays a `.click` haptic on every successful log.
// - Calls the `send` closure (queues a peer-to-peer message via
//   WatchConnectivity). No HTTP, no analytics — see §13.
// - Mutates `@Published` state on the main queue.

import Foundation
import Combine
import WatchKit

final class ShotLogger: ObservableObject {
    @Published private(set) var shotCount: Int = 0
    @Published private(set) var lastSource: String?
    @Published private(set) var lastAt: Date?

    /// Bound by the app delegate to push the payload to the iPhone.
    var send: (([String: Any]) -> Void)?

    func log(source: String, peakG: Double? = nil, rangeYd: Double? = nil) {
        let now = Date()
        var payload: [String: Any] = [
            "at": Int(now.timeIntervalSince1970 * 1000),
            "src": source
        ]
        if let r = rangeYd { payload["r"] = r }
        if let g = peakG { payload["g"] = g }
        send?(payload)

        DispatchQueue.main.async { [weak self] in
            self?.shotCount += 1
            self?.lastAt = now
            self?.lastSource = source
        }

        // Confirmation haptic — distinct tap so the user knows the
        // log went through even if they're not looking at the wrist.
        WKInterfaceDevice.current().play(.click)
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.shotCount = 0
            self?.lastAt = nil
            self?.lastSource = nil
        }
    }
}
