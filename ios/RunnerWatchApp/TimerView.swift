// FILE: ios/RunnerWatchApp/TimerView.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// SwiftUI view for the stage-timer tab on the watch (Feature 1).
// Reads a `TimerEngine` from the SwiftUI environment and renders:
//   * Big rounded-design numerals showing `m:ss`.
//   * A state label (`READY · 1:30` / `RUNNING` / `PAUSED` / `DONE`).
//   * `-30` and `+30` adjuster buttons (only enabled while idle).
//   * A primary Start / Pause / Resume / Restart action whose label
//     and tint colour change with state.
//   * A reset button + a quiet-mode toggle in a footer row.
//
// All state lives on the engine; the view is purely declarative —
// it observes `@EnvironmentObject` and rebuilds.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// One of three feature views hosted by `ContentView`'s `TabView`. The
// view is the user-facing surface of `TimerEngine` — keeping them
// separated lets the engine be unit-testable without a SwiftUI host
// and lets the view be swapped out (different layouts for round vs
// rectangular watch faces, e.g.) without touching timing logic.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`stateColor` returns `.red` only at ≤5 seconds remaining.**
//    Anything at 10 turns orange, 5 turns red, the rest is the
//    default primary. The thresholds match the engine's warning
//    checkpoints so the visual cue and the audio cue land at the
//    same time. Diverge them and the UX feels broken.
//
// 2. **The primary button's `Restart` label after `.finished` is
//    deliberate.** Reusing the same button for "now do it again"
//    instead of disabling it lets the user dry-fire stages back to
//    back without having to hit reset. Tapping `Restart` calls
//    `engine.start()`, which the engine treats as "start over from
//    `totalSec`" because `state == .finished`.
//
// 3. **`monospacedDigit()` is essential.** Without it, the `:` and
//    each digit would have proportional widths and the numerals
//    would jitter horizontally as they tick down. Even one frame of
//    jitter is distracting at the line.
//
// 4. **`Toggle.toggleStyle(.button)` rather than `.switch`.** A
//    one-tap button is faster than dragging a switch on a small
//    watch face, and on watchOS the button-style toggle renders as a
//    pressed/unpressed icon — which reads as quiet/loud at a glance.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `ContentView.swift` — hosts this as the first page in the
//   horizontal `TabView`.
// - `TimerEngine.swift` — read via `@EnvironmentObject`.
//   `LoadOutWatchApp` injects it.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None directly. All side effects (haptics, audio, sends to phone)
// happen inside the engine when the view's button taps drive its
// methods.

import SwiftUI

struct TimerView: View {
    @EnvironmentObject private var engine: TimerEngine

    var body: some View {
        VStack(spacing: 6) {
            Text(formatted(engine.remainingSec))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stateColor)
                .padding(.top, 4)

            Text(stateLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: { engine.adjust(by: -30) }) {
                    Text("-30")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .disabled(engine.state != .idle)

                Button(action: { engine.adjust(by: 30) }) {
                    Text("+30")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .disabled(engine.state != .idle)
            }
            .buttonStyle(.bordered)

            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryTint)

            HStack(spacing: 8) {
                Button(action: { engine.reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(engine.state == .idle)

                Toggle(isOn: Binding(
                    get: { engine.quietMode },
                    set: { engine.setQuietMode($0) }
                )) {
                    Image(systemName: engine.quietMode ? "speaker.slash" : "speaker.wave.2")
                        .imageScale(.small)
                }
                .toggleStyle(.button)
            }
            .font(.caption2)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Helpers

    private func primaryAction() {
        switch engine.state {
        case .idle, .finished:
            engine.start()
        case .running:
            engine.pause()
        case .paused:
            engine.resume()
        }
    }

    private var primaryLabel: String {
        switch engine.state {
        case .idle:     return "Start"
        case .running:  return "Pause"
        case .paused:   return "Resume"
        case .finished: return "Restart"
        }
    }

    private var primaryTint: Color {
        switch engine.state {
        case .idle, .finished: return .green
        case .running:         return .orange
        case .paused:          return .blue
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle:     return "READY · \(formatted(engine.totalSec))"
        case .running:  return "RUNNING"
        case .paused:   return "PAUSED"
        case .finished: return "DONE"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .idle:     return .primary
        case .running:
            if engine.remainingSec <= 5 { return .red }
            if engine.remainingSec <= 10 { return .orange }
            return .primary
        case .paused:   return .blue
        case .finished: return .red
        }
    }

    private func formatted(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

#Preview {
    TimerView()
        .environmentObject(TimerEngine())
}
