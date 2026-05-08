// FILE: ios/RunnerWatchApp/DopeViewModel.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Watch-side decoder + state holder for `dope`, `active_load`, and
// `firearm_glance` payloads received from the iPhone over the
// WatchConnectivity bridge.
//
// Public surface:
//   * `struct DopeRow` (Identifiable, Equatable) — one row of the
//     ballistic ladder.
//   * `struct DopeSnapshot` (Equatable) — the full snapshot the
//     watch displays.
//   * `struct ActiveLoadSnapshot` (Equatable) — the active recipe
//     summary.
//   * `final class DopeViewModel: ObservableObject`:
//     - `@Published var snapshot: DopeSnapshot?`
//     - `@Published var activeLoad: ActiveLoadSnapshot?`
//     - `@Published var rowCursor: Int` — the user's scroll
//       position, modified by `nextRow()` / `previousRow()`.
//     - `func handle(path:payload:)` — the dispatch entry point
//       called from the connectivity manager.
//     - `func currentRow() -> DopeRow?` — convenience for views.
//
// Wire format (mirrors `lib/models/watch_payloads.dart` exactly):
//   * DOPE row keys: `r/u/w/v/t` (range, up, wind, velocity, time-of-flight).
//   * Snapshot keys: `cart`, `bgr`, `bn`, `mv`, `z`, `ws`, `wd`, `dm`,
//     `bc`, `pn`, `fn`, `g`, `rows`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// SwiftUI views need typed structs, not raw `[String: Any]`
// dictionaries. This file is the codec layer between the
// connectivity manager (which speaks dictionaries) and the views
// (which want `DopeRow`s). It also owns the cursor state — the
// user's scroll position through the ladder — because that's
// shared between `DopeView` (drives the digital-crown UI) and
// `StageLogView` (advances the cursor after each shot).
//
// Without this file, `DopeView` would have to cast NSNumbers and
// downcast strings on every render, which is both slow and brittle.
//
// (For Swift newcomers: `ObservableObject` + `@Published` is the
// canonical view-model pattern. `@Published` properties trigger
// SwiftUI rebuilds when written. We always hop to `DispatchQueue.main`
// before mutating because the connectivity callbacks fire on a
// background queue.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`NSNumber` casts are required for cross-language ints.**
//    Wear OS / iOS pass numeric values through Apple's binary
//    codec; what arrives at the watch is `NSNumber`, not a typed
//    `Int` or `Double`. `(payload["mv"] as? NSNumber)?.doubleValue`
//    is the correct decode; `as? Double` would fail on integer-typed
//    senders. This caught us in early dev when the iPhone was
//    sending `Int` values for muzzle velocity and the watch was
//    silently rejecting every snapshot.
//
// 2. **Optional-string decode for `pn` / `fn`.** Profile and firearm
//    name are nullable on the wire. Always decode with
//    `payload["pn"] as? String`, never `as! String` — the bang form
//    crashes when the field is omitted.
//
// 3. **Cursor clamping after a new snapshot.** When a fresh snapshot
//    arrives with fewer rows than the previous one, the cursor
//    might point past the new end. We clamp to `rows.count - 1`
//    (or 0 for empty) so the view never tries to read out of bounds.
//
// 4. **`firearm_glance` is intentionally a no-op for now.** The
//    path is reserved (CLAUDE.md §15) but Feature 2 doesn't render
//    a firearm tab. Leaving the case in the switch ensures payloads
//    are absorbed rather than logged as errors when the phone
//    eventually starts sending them.
//
// 5. **`ActiveLoadSnapshot` ignores fields it doesn't display.**
//    The wire format includes powder name, charge, primer, brass,
//    COAL, CBTO. The watch view shows only name + cartridge +
//    powder + bullet, so we decode just those. Adding more fields
//    later means extending the struct AND the decode — both must
//    happen together.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `WatchAppDelegate.swift` — instantiates one and binds it to
//   `connectivity.onIncoming`.
// - `LoadOutWatchApp.swift` — injects into the SwiftUI environment.
// - `DopeView.swift` — reads `snapshot` + `currentRow()` and calls
//   `nextRow()` / `previousRow()` from the digital crown.
// - `StageLogView.swift` — reads `currentRow()` to know "what range
//   is next?" and calls `nextRow()` after each shot.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Mutates `@Published` state on the main queue. Each mutation
//   triggers a SwiftUI rebuild of any view observing the model.
// - No I/O — pure decoder.

import Foundation
import Combine

struct DopeRow: Identifiable, Equatable {
    let rangeYd: Int
    let dropMil: Double
    let windMil: Double
    let velocityFps: Double
    let timeOfFlightSec: Double

    var id: Int { rangeYd }
}

struct DopeSnapshot: Equatable {
    let cartridgeName: String
    let bulletGr: Double
    let bulletName: String
    let muzzleVelocityFps: Double
    let zeroRangeYd: Int
    let windSpeedMph: Double
    let windFromDeg: Double
    let dragModel: String
    let bc: Double
    let profileName: String?
    let firearmName: String?
    let generatedAt: Date
    let rows: [DopeRow]
}

struct ActiveLoadSnapshot: Equatable {
    let name: String
    let cartridgeName: String
    let powderName: String?
    let powderChargeGr: Double?
    let bulletName: String?
    let bulletWeightGr: Double?
}

final class DopeViewModel: ObservableObject {
    @Published private(set) var snapshot: DopeSnapshot?
    @Published private(set) var activeLoad: ActiveLoadSnapshot?

    /// 0-based cursor into `snapshot.rows`. Persists as the user
    /// scrolls; clamped to row bounds when a new snapshot lands.
    @Published var rowCursor: Int = 0

    func handle(path: String, payload: [String: Any]) {
        switch path {
        case WatchPaths.dope:
            ingestDope(payload: payload)
        case WatchPaths.activeLoad:
            ingestActiveLoad(payload: payload)
        case WatchPaths.firearmGlance:
            // Reserved for future tab — not consumed by Feature 2 yet.
            break
        default:
            break
        }
    }

    func nextRow() {
        guard let rows = snapshot?.rows, !rows.isEmpty else { return }
        rowCursor = min(rowCursor + 1, rows.count - 1)
    }

    func previousRow() {
        guard let rows = snapshot?.rows, !rows.isEmpty else { return }
        rowCursor = max(rowCursor - 1, 0)
    }

    func currentRow() -> DopeRow? {
        guard let rows = snapshot?.rows else { return nil }
        guard rowCursor >= 0, rowCursor < rows.count else { return nil }
        return rows[rowCursor]
    }

    // MARK: - Decoding

    private func ingestDope(payload: [String: Any]) {
        guard let cart = payload["cart"] as? String,
              let mv = (payload["mv"] as? NSNumber)?.doubleValue,
              let z = (payload["z"] as? NSNumber)?.intValue,
              let dm = payload["dm"] as? String,
              let bc = (payload["bc"] as? NSNumber)?.doubleValue,
              let bgr = (payload["bgr"] as? NSNumber)?.doubleValue,
              let bn = payload["bn"] as? String,
              let rowsRaw = payload["rows"] as? [[String: Any]] else {
            return
        }
        let rows: [DopeRow] = rowsRaw.compactMap { dict in
            guard let r = (dict["r"] as? NSNumber)?.intValue,
                  let u = (dict["u"] as? NSNumber)?.doubleValue,
                  let w = (dict["w"] as? NSNumber)?.doubleValue,
                  let v = (dict["v"] as? NSNumber)?.doubleValue,
                  let t = (dict["t"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return DopeRow(rangeYd: r,
                           dropMil: u,
                           windMil: w,
                           velocityFps: v,
                           timeOfFlightSec: t)
        }
        let ws = (payload["ws"] as? NSNumber)?.doubleValue ?? 0
        let wd = (payload["wd"] as? NSNumber)?.doubleValue ?? 0
        let pn = payload["pn"] as? String
        let fn = payload["fn"] as? String
        let generatedAtMs = (payload["g"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        let snap = DopeSnapshot(
            cartridgeName: cart,
            bulletGr: bgr,
            bulletName: bn,
            muzzleVelocityFps: mv,
            zeroRangeYd: z,
            windSpeedMph: ws,
            windFromDeg: wd,
            dragModel: dm,
            bc: bc,
            profileName: pn,
            firearmName: fn,
            generatedAt: Date(timeIntervalSince1970: generatedAtMs / 1000.0),
            rows: rows
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snap
            // Clamp cursor to current ladder.
            if !rows.isEmpty {
                self.rowCursor = min(self.rowCursor, rows.count - 1)
            } else {
                self.rowCursor = 0
            }
        }
    }

    private func ingestActiveLoad(payload: [String: Any]) {
        guard let name = payload["n"] as? String,
              let cart = payload["cart"] as? String else {
            return
        }
        let snap = ActiveLoadSnapshot(
            name: name,
            cartridgeName: cart,
            powderName: payload["p"] as? String,
            powderChargeGr: (payload["pgr"] as? NSNumber)?.doubleValue,
            bulletName: payload["b"] as? String,
            bulletWeightGr: (payload["bgr"] as? NSNumber)?.doubleValue
        )
        DispatchQueue.main.async { [weak self] in
            self?.activeLoad = snap
        }
    }
}
