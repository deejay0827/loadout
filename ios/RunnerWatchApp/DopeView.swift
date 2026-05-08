// FILE: ios/RunnerWatchApp/DopeView.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// SwiftUI view for the DOPE tab on the watch (Feature 2). Reads a
// `DopeViewModel` from the SwiftUI environment and renders, when a
// snapshot is available, a glanceable card with:
//
//   * Header: cartridge + bullet identity (e.g. "6.5 Creedmoor · 140 ELD-M").
//   * Big rounded numerals for the current range in yards.
//   * Two columns: vertical "UP" hold in mils and horizontal "WIND"
//     hold in mils.
//   * Prev / Next arrow buttons for finger scrolling.
//
// The digital crown is wired via `.digitalCrownRotation(...)`; each
// integer step (`crownStep`) of crown rotation moves the cursor by
// one row, capped at 3 rows per fired event so a quick spin doesn't
// blow past the end of the ladder.
//
// When the view-model has no snapshot yet, a fallback "Waiting for
// DOPE — open Ballistics on your iPhone" view renders.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One of three feature views hosted by `ContentView`'s `TabView`.
// The DOPE card is the user's at-a-glance reference at the line —
// "what dial do I turn for this range?". Keeping the view stateless
// (state lives in `DopeViewModel`) lets us preview the populated
// state with a mock model and unit-test the model independently.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`focusable(true)` is required for the digital crown.**
//    Without it, `.digitalCrownRotation(...)` silently no-ops on
//    real hardware. It works in previews because previews don't
//    enforce focus, which led to a fun debug session in early dev.
//
// 2. **Crown delta is binned before consuming.** The crown publishes
//    a continuous, monotonic-ish stream — a quick spin can produce
//    delta values much larger than 1. We `.rounded()` to integer,
//    cap at 3 steps per event, and reset `crownDelta = 0` so the
//    user has to keep spinning to keep moving. Without the cap, a
//    flick of the crown would skip from 100 yd to 1500 yd
//    instantaneously and the user would lose orientation.
//
// 3. **`.sensitivity: .low` matches the small ladder size.** A
//    typical DOPE table is 8–15 rows. `.high` makes the crown feel
//    twitchy; `.low` makes one full crown rotation roughly equal
//    one pass through the ladder. Adjusting this is fine but pair
//    it with the cap-at-3 logic.
//
// 4. **Header truncation uses `.lineLimit(1)`.** Long load names
//    ("300 Norma Mag 230 Berger Hybrid OTM") would overflow the
//    watch face. The line limit + the system's mid-ellipsis
//    truncation keeps the cartridge prefix and bullet line legible.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `ContentView.swift` — hosts this as the second page in the
//   horizontal `TabView`.
// - `DopeViewModel.swift` — read via `@EnvironmentObject`. Receives
//   `dope` and `active_load` payloads from the phone and exposes
//   them as `snapshot`.
// - `StageLogView.swift` — also reads the DOPE model to advance
//   the cursor after each logged shot.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None directly. The crown drives `model.nextRow()` /
// `previousRow()`, which mutate the model's published `rowCursor`.
// No I/O, no audio.

import SwiftUI

struct DopeView: View {
    @EnvironmentObject private var model: DopeViewModel
    @State private var crownDelta: Double = 0
    private let crownStep: Double = 1.0

    var body: some View {
        if let snap = model.snapshot, let row = model.currentRow() {
            populated(snap: snap, row: row)
        } else {
            empty
        }
    }

    // MARK: - Populated state

    private func populated(snap: DopeSnapshot, row: DopeRow) -> some View {
        VStack(spacing: 4) {
            // Header — load identity. Truncates with mid-ellipsis so
            // long names ("300 Norma Mag 230 Berger Hybrid OTM") still
            // show the cartridge and bullet line.
            Text(headerText(snap))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Range row — the one piece of state the user is scrolling
            // through. Big numerals.
            VStack(spacing: 2) {
                Text("\(row.rangeYd)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("YARDS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
            }
            .padding(.top, 2)

            // Solution.
            HStack(spacing: 12) {
                holdColumn(label: "UP", value: row.dropMil)
                holdColumn(label: "WIND", value: row.windMil)
            }
            .padding(.top, 2)

            // Range scroll controls.
            HStack(spacing: 8) {
                Button(action: { model.previousRow() }) {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { model.nextRow() }) {
                    Image(systemName: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
        .padding(.horizontal, 6)
        .focusable(true)
        .digitalCrownRotation(
            $crownDelta,
            from: -100,
            through: 100,
            by: crownStep,
            sensitivity: .low,
            isContinuous: true,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownDelta) { _, newValue in
            handleCrown(newValue)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Waiting for DOPE")
                .font(.caption)
            Text("Open the Ballistics screen on your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Helpers

    private func headerText(_ snap: DopeSnapshot) -> String {
        let bw = String(format: "%.0f", snap.bulletGr)
        return "\(snap.cartridgeName) · \(bw) \(snap.bulletName)"
    }

    private func holdColumn(label: String, value: Double) -> some View {
        VStack(spacing: 0) {
            Text(formattedMil(value))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(1)
        }
    }

    private func formattedMil(_ value: Double) -> String {
        return String(format: "%.1f mil", value)
    }

    private func handleCrown(_ value: Double) {
        // The crown publishes a continuous, monotonic-ish stream. Bin
        // it into integer steps and translate each step into one row
        // movement.
        let steps = Int(value.rounded())
        if steps == 0 { return }
        if steps > 0 {
            for _ in 0..<min(steps, 3) { model.nextRow() }
        } else {
            for _ in 0..<min(-steps, 3) { model.previousRow() }
        }
        crownDelta = 0
    }
}

#Preview {
    let model = DopeViewModel()
    model.handle(path: WatchPaths.dope, payload: [
        "cart": "6.5 Creedmoor",
        "bgr": 140,
        "bn": "ELD-M",
        "mv": 2750,
        "z": 100,
        "ws": 8.0,
        "wd": 270,
        "dm": "g7",
        "bc": 0.315,
        "g": Int(Date().timeIntervalSince1970 * 1000),
        "rows": [
            ["r": 100, "u": 0.0, "w": 0.0, "v": 2750, "t": 0.11],
            ["r": 200, "u": 0.6, "w": 0.2, "v": 2620, "t": 0.23],
            ["r": 600, "u": 5.4, "w": 0.8, "v": 1780, "t": 0.92],
            ["r": 1000, "u": 12.4, "w": 2.4, "v": 1180, "t": 1.79],
        ]
    ])
    return DopeView()
        .environmentObject(model)
}
