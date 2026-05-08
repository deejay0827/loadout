// FILE: ios/RunnerWatchApp/StageLogView.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// SwiftUI view for the Stage Log tab on the watch (Feature 3). Three
// ways for the user to log a shot:
//   1. **Motion detection.** A `MotionDetector` instance polls the
//      accelerometer; when it surfaces `pendingShotPeakG`, this view
//      shows a 5-second confirm prompt with Skip / Log buttons. If
//      the user does nothing, the auto-confirm timer fires the log.
//   2. **Manual tap.** A big "Log Shot" button always available when
//      no candidate is pending.
//   3. **Swipe gestures.** Drag right ≥24 px = log; drag left ≥24 px
//      = skip (advances DOPE without logging).
//
// After every log AND every skip, `DopeViewModel.nextRow()` advances
// the DOPE card to the next range bin so the user sees the dial for
// the next shot without lifting their wrist.
//
// A settings sheet exposes:
//   * Motion-detect on/off toggle (off-screen pauses the
//     accelerometer to save battery).
//   * Threshold slider (3.0–10.0 g, default 5.0).
//   * Clear-count button.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Stage Log is the highest-frequency interaction on the watch — at
// the line, the user fires multiple shots per minute. Combining
// motion + swipe + manual tap into one view (rather than three
// separate screens) means the user never has to navigate to log a
// shot. The view sits in the third tab of `ContentView`'s `TabView`,
// reachable by one swipe.
//
// Bringing the logger, the motion detector, and the DOPE cursor
// together in a single view is also why the side-effect ordering is
// correct: every code path that registers a shot also calls
// `dope.nextRow()` so the UI advances. If `ShotLogger.log()` did
// that itself, the flow would be cleaner — but `ShotLogger` would
// then have to know about `DopeViewModel`, which it shouldn't.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`@StateObject` (not `@EnvironmentObject`) for the detector.**
//    The motion detector lives PER-INSTANCE of this view because we
//    only want the accelerometer running while Stage Log is visible.
//    Lifting it to the app delegate would mean polling the
//    accelerometer all the time, draining the watch battery for no
//    reason on the Timer or DOPE tabs.
//
// 2. **Auto-confirm uses a `Task` we explicitly cancel.** Without
//    cancellation, a stale auto-confirm fires after the user
//    manually skipped or after a NEW candidate landed. The
//    `autoConfirmTask?.cancel()` calls in every state transition
//    keep the queue at most one. The `try? await Task.sleep(...)`
//    is the canonical SwiftUI/structured-concurrency idiom for "do
//    X in N seconds unless cancelled".
//
// 3. **`onDisappear` stops the detector AND cancels the task.**
//    Without this, the user could swipe to the DOPE tab while the
//    auto-confirm timer is in flight; the timer would fire, log a
//    shot they didn't ask for, and surface no UI to undo it.
//
// 4. **Drag thresholds are in points, not normalized.** 24 pt is
//    enough to distinguish a swipe from a jitter-tap on a real
//    Apple Watch face but small enough that gloved fingers can hit
//    it. Beware: SwiftUI's `DragGesture(minimumDistance: 30)` is the
//    THRESHOLD for the gesture starting; 24 is the trigger inside
//    `onEnded`. Both are intentionally tight to feel responsive at
//    the line.
//
// 5. **Logging from the manual button does NOT route through the
//    motion confirm flow.** Manual taps log immediately with
//    `source: ShotSource.manual` and no peakG. The motion
//    confirmation flow is specifically for accelerometer-detected
//    candidates so the user can veto false positives.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `ContentView.swift` — hosts this as the third page in the
//   horizontal `TabView`.
// - `ShotLogger.swift` — `@EnvironmentObject` reading. Each log call
//   is a side-effect of a user gesture in this view.
// - `DopeViewModel.swift` — `@EnvironmentObject` reading. Used to
//   know "what range is next?" and to advance the cursor.
// - `MotionDetector.swift` — owned per-instance via `@StateObject`.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Starts the accelerometer when the view appears, stops on
//   disappear.
// - Logs shots via `ShotLogger.log(...)`, which queues a peer-to-
//   peer payload to the iPhone (no HTTP).
// - Advances the DOPE cursor on every shot or skip.

import SwiftUI

struct StageLogView: View {
    @EnvironmentObject private var logger: ShotLogger
    @EnvironmentObject private var dope: DopeViewModel
    @StateObject private var motion = MotionDetector()

    @State private var autoConfirmTask: Task<Void, Never>?
    @State private var showSettings: Bool = false
    @State private var motionEnabled: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 6)
        .onAppear {
            if motionEnabled { motion.start() }
        }
        .onDisappear {
            motion.stop()
            autoConfirmTask?.cancel()
        }
        .onChange(of: motion.pendingShotPeakG) { _, newValue in
            handlePending(newValue)
        }
        .onChange(of: motionEnabled) { _, on in
            if on { motion.start() } else { motion.stop() }
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("STAGE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Text("\(logger.shotCount) shot\(logger.shotCount == 1 ? "" : "s")")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .imageScale(.medium)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let peak = motion.pendingShotPeakG {
            confirmPrompt(peak: peak)
        } else {
            swipeArea
        }
    }

    private func confirmPrompt(peak: Double) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Shot detected")
                .font(.callout)
                .fontWeight(.semibold)
            Text(String(format: "%.1f g", peak))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: dismissCandidate) {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: confirmCandidate) {
                    Text("Log")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .font(.caption)

            Text("Auto-logs in 5 s")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var swipeArea: some View {
        VStack(spacing: 4) {
            // Big tap target for manual log.
            Button(action: logManual) {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.title2)
                    Text("Log Shot")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            HStack(spacing: 8) {
                if let snap = dope.snapshot, let row = dope.currentRow() {
                    Text("Next: \(row.rangeYd) yd")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    let _ = snap // silence unused
                } else {
                    Text("No DOPE")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            Text("Swipe → log · ← skip")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded(handleSwipe)
        )
    }

    private var settingsSheet: some View {
        VStack(spacing: 8) {
            Text("Stage Log Settings")
                .font(.headline)
            Toggle("Motion detect", isOn: $motionEnabled)
                .font(.caption)
            VStack(alignment: .leading) {
                Text(String(format: "Threshold: %.1f g", motion.thresholdG))
                    .font(.caption)
                Slider(value: Binding(
                    get: { motion.thresholdG },
                    set: { motion.thresholdG = $0 }
                ), in: 3.0...10.0, step: 0.5)
            }
            Button(action: {
                logger.clear()
                showSettings = false
            }) {
                Text("Clear shot count")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Button(action: { showSettings = false }) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func handlePending(_ peak: Double?) {
        autoConfirmTask?.cancel()
        guard peak != nil else { return }
        // Auto-confirm in 5 s if the user doesn't react.
        autoConfirmTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if motion.pendingShotPeakG != nil {
                    confirmCandidate()
                }
            }
        }
    }

    private func confirmCandidate() {
        let peak = motion.acknowledge()
        autoConfirmTask?.cancel()
        autoConfirmTask = nil
        let range = dope.currentRow()?.rangeYd
        logger.log(
            source: ShotSource.motion,
            peakG: peak,
            rangeYd: range.map { Double($0) }
        )
        // Advance to the next DOPE row so the user sees the next dial.
        dope.nextRow()
    }

    private func dismissCandidate() {
        motion.dismiss()
        autoConfirmTask?.cancel()
        autoConfirmTask = nil
    }

    private func logManual() {
        let range = dope.currentRow()?.rangeYd
        logger.log(source: ShotSource.manual, rangeYd: range.map { Double($0) })
        dope.nextRow()
    }

    private func handleSwipe(_ value: DragGesture.Value) {
        let dx = value.translation.width
        if dx > 24 {
            let range = dope.currentRow()?.rangeYd
            logger.log(source: ShotSource.swipe, rangeYd: range.map { Double($0) })
            dope.nextRow()
        } else if dx < -24 {
            // "Skip" — advance DOPE without logging a shot.
            dope.nextRow()
        }
    }
}

#Preview {
    StageLogView()
        .environmentObject(ShotLogger())
        .environmentObject(DopeViewModel())
}
