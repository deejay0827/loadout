// FILE: ios/RunnerWatchApp/TimerEngine.swift
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Stage timer view-model for Feature 1 of the watch companion. Runs a
// 1-Hz countdown, fires haptic + audio cues at warning checkpoints,
// and emits `timer_event` payloads to the iPhone so it can mirror
// state if foreground.
//
// Public surface:
//   * `enum TimerState` — `.idle | .running | .paused | .finished`.
//   * `@Published var totalSec`, `remainingSec`, `state`, `quietMode`
//     — SwiftUI observes these and rebuilds when they change.
//   * `var send: (([String: Any]) -> Void)?` — bound by the app
//     delegate to push timer events to the phone. Optional — the
//     timer works fully without it.
//   * `func setQuietMode(_:)` — persisted under
//     `timer.quietMode`.
//   * `func adjust(by:)` — only valid while idle; bumps the total
//     duration in seconds (clamped to ≥5).
//   * `func start()`, `pause()`, `resume()`, `reset()` — drive the
//     state machine.
//
// At every `start`, the engine clears the warning checkpoint set so
// repeat runs fire all warnings again. At every `tick` while running,
// the engine decrements `remainingSec`, checks the warning list, and
// transitions to `.finished` at zero.
//
// Last-used `totalSec` and `quietMode` persist in `UserDefaults`
// under `timer.lastDuration` and `timer.quietMode`.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// PRS / NRL / 3-Gun match stages run on a tight clock. The watch's
// haptics and speaker are more reliable signals at the line than
// fumbling for the phone. The whole engine intentionally runs
// **entirely on the watch** — phone connectivity is optional, used
// only to mirror state to the phone for cross-device awareness.
//
// Splitting the timer logic out of `TimerView.swift` keeps the view
// purely declarative (read state, emit user actions) while the engine
// owns timing, persistence, and audio. Under unit test, the engine is
// instantiable without a SwiftUI environment.
//
// (For SwiftUI newcomers: `ObservableObject` + `@Published` is the
// canonical view-model pattern. SwiftUI subscribes a view to the
// engine and rebuilds the view whenever any `@Published` property
// changes. We do all `@Published` writes on the main thread so
// SwiftUI's diffing stays consistent.)
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **`Timer` runs on a RunLoop, not a Combine clock.** We
//    explicitly add the timer to `RunLoop.main` with
//    `.common` mode so the countdown keeps firing while the user
//    interacts with another tab (the digital crown rotation in
//    DopeView would otherwise pause `.default`-mode timers).
//
// 2. **Haptics fire even in quiet mode.** Quiet mode silences the
//    SPEAKER, not the wrist. The whole point of "quiet mode" on a
//    watch is "I want haptics-only" — silencing both would mean the
//    user gets no feedback and the timer is useless. If you ever
//    refactor, preserve this asymmetry.
//
// 3. **`AVAudioSession.duckOthers` matters at the range.** When the
//    user has music or a coaching podcast playing on AirPods, the
//    timer beep should DUCK the music down, beep, then restore.
//    Using `.duckOthers` does this; using `.mixWithOthers` would
//    overlap (cacophonous), and using neither would cut the music
//    entirely (worse).
//
// 4. **`ToneGenerator` is a private helper, not nested.** It lives at
//    file scope so SwiftUI previews don't accidentally serialize an
//    AVAudioEngine reference. AVAudioEngine has internal state that
//    fights when the same instance is shared across previews; keeping
//    it module-private and singleton-shared sidesteps the issue.
//
// 5. **`triggeredWarnings` is a `Set<Int>`, not a count.** The set
//    means each checkpoint fires exactly once per run, even if the
//    user pauses just past it and resumes BEFORE the tick that would
//    decrement past again. Without the set, a paused-then-resumed
//    pair could double-beep on the same checkpoint.
//
// 6. **`emit` is best-effort and fires on every state transition.**
//    The phone might not be reachable. We don't gate state changes
//    on send-success — losing a `pause` payload doesn't break the
//    timer, just the phone's mirror.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `TimerView.swift` — reads every `@Published` property and calls
//   the public methods on user gesture.
// - `WatchAppDelegate.swift` — instantiates the engine, binds
//   `engine.send` to the connectivity manager.
// - `LoadOutWatchApp.swift` — injects the engine into the SwiftUI
//   environment.
//
// File ships on disk but only enters the Xcode build once the
// operator follows the watch-target wire-up in CLAUDE.md §15.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads / writes `UserDefaults` under `timer.lastDuration` and
//   `timer.quietMode`.
// - Plays haptics via `WKInterfaceDevice.current().play(...)`.
// - Plays speaker tones via `AVAudioEngine` (only when `quietMode`
//   is off).
// - Calls `send` on every state transition — sends `timer_event`
//   payloads peer-to-peer to the iPhone via WatchConnectivity. No
//   HTTP, no analytics.

import Foundation
import Combine
import WatchKit
import AVFoundation

final class TimerEngine: ObservableObject {
    // MARK: - Persisted preferences

    private let defaults = UserDefaults.standard
    private let kLastDuration = "timer.lastDuration"
    private let kQuietMode = "timer.quietMode"

    /// Convenience: full set of warning checkpoints in seconds-remaining.
    private let warningPoints: [Int] = [30, 10, 5]

    // MARK: - Public state

    @Published var totalSec: Int = 90
    @Published var remainingSec: Int = 90
    @Published var state: TimerState = .idle
    @Published var quietMode: Bool = false

    /// Optional sender — wired by the app delegate so timer events can
    /// (best-effort) be mirrored to the phone for cross-device display.
    /// Never required for correct operation; safe to leave nil.
    var send: (([String: Any]) -> Void)?

    enum TimerState: String {
        case idle, running, paused, finished
    }

    // MARK: - Internal

    private var timer: Timer?
    private var triggeredWarnings: Set<Int> = []

    init() {
        // Restore last-used duration. New installs default to 90 s.
        let saved = defaults.integer(forKey: kLastDuration)
        if saved > 0 {
            totalSec = saved
            remainingSec = saved
        }
        quietMode = defaults.bool(forKey: kQuietMode)
    }

    // MARK: - Controls

    func setQuietMode(_ on: Bool) {
        quietMode = on
        defaults.set(on, forKey: kQuietMode)
    }

    func adjust(by seconds: Int) {
        guard state == .idle else { return }
        totalSec = max(5, totalSec + seconds)
        remainingSec = totalSec
        defaults.set(totalSec, forKey: kLastDuration)
    }

    func start() {
        if state == .running { return }
        if state == .finished || state == .idle {
            remainingSec = totalSec
            triggeredWarnings.removeAll()
        }
        state = .running
        scheduleTick()
        beep(.start)
        emit(kind: "start", remaining: remainingSec, total: totalSec)
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        timer?.invalidate()
        timer = nil
        emit(kind: "pause", remaining: remainingSec, total: totalSec)
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
        scheduleTick()
        emit(kind: "resume", remaining: remainingSec, total: totalSec)
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        remainingSec = totalSec
        triggeredWarnings.removeAll()
        state = .idle
        emit(kind: "reset", remaining: remainingSec, total: totalSec)
    }

    // MARK: - Tick

    private func scheduleTick() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer = t
        // Fire on the run loop so the watch UI updates while the wrist
        // is up. `.common` keeps the timer running while user is
        // interacting with another tab.
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        guard state == .running else { return }
        remainingSec -= 1
        if warningPoints.contains(remainingSec) && !triggeredWarnings.contains(remainingSec) {
            triggeredWarnings.insert(remainingSec)
            beep(.warning)
            emit(kind: "warning", remaining: remainingSec, total: totalSec)
        }
        if remainingSec <= 0 {
            remainingSec = 0
            timer?.invalidate()
            timer = nil
            state = .finished
            beep(.expired)
            emit(kind: "expired", remaining: 0, total: totalSec)
        }
    }

    // MARK: - Haptics + audio

    enum Cue {
        case start, warning, expired
    }

    private func beep(_ cue: Cue) {
        // Haptics always fire — they're not gated by quiet mode (the
        // wrist tap IS the quiet-mode signal).
        let device = WKInterfaceDevice.current()
        switch cue {
        case .start:
            device.play(.start)
        case .warning:
            device.play(.notification)
        case .expired:
            device.play(.success)
        }

        if quietMode { return }

        // Speaker tone — short tone for warnings, longer for final.
        // We use a silent-by-default audio session so other media
        // resumes after the tone plays.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // Audio failures are non-fatal — the haptic already fired.
            return
        }
        let frequency: Double
        let duration: Double
        switch cue {
        case .start:    frequency = 880;  duration = 0.18
        case .warning:  frequency = 880;  duration = 0.10
        case .expired:  frequency = 1320; duration = 0.45
        }
        ToneGenerator.shared.play(frequency: frequency, duration: duration)
    }

    private func emit(kind: String, remaining: Int, total: Int) {
        let payload: [String: Any] = [
            "k": kind,
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "rem": remaining,
            "tot": total
        ]
        send?(payload)
    }

    deinit {
        timer?.invalidate()
    }
}

/// Tiny utility wrapping AVAudioEngine for one-shot sine-wave tones.
/// Lives at the file scope (not nested in TimerEngine) so SwiftUI
/// previews don't try to serialize an engine reference.
private final class ToneGenerator {
    static let shared = ToneGenerator()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var prepared = false

    func play(frequency: Double, duration: Double) {
        let sampleRate: Double = 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        if !prepared {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
                prepared = true
            } catch {
                return
            }
        }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let theta = 2.0 * Double.pi * frequency / sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                channel[i] = Float(sin(theta * Double(i)) * 0.5)
            }
        }

        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }
}
