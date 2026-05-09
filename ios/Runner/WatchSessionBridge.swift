// WatchSessionBridge.swift
// iPhone-side companion to `RunnerWatchApp/WatchConnectivityManager.swift`.
//
// Lives in the Flutter Runner target. Activates a WCSession at app launch
// and exposes a small surface to Dart over a MethodChannel so future
// feature code (DOPE glance, shot logging, load picker) can talk to the
// watch without writing more Swift each time.
//
// Wiring (currently live in `AppDelegate.swift`):
//   - Runner uses Flutter's newer `FlutterImplicitEngineDelegate` pattern,
//     so the activation site is `didInitializeImplicitFlutterEngine` —
//     not `didFinishLaunchingWithOptions`. The delegate hands us a
//     `FlutterImplicitEngineBridge`; pulling a registrar out of its
//     `pluginRegistry` gives a `FlutterBinaryMessenger`, which is all
//     this bridge actually needs to construct the MethodChannel /
//     EventChannel pair. See `activate(messenger:)`.
//   - On the Dart side, see `lib/services/watch_bridge_service.dart`
//     for the matching MethodChannel client.
//
// One file change required outside this directory: confirm this file is
// added to the **Runner** target in `Runner.xcworkspace` (Build Phases →
// Compile Sources). It is NOT auto-discovered the way Pods are.

import Foundation
import Flutter
import WatchConnectivity

final class WatchSessionBridge: NSObject {
    static let shared = WatchSessionBridge()

    /// MethodChannel name shared with Dart. Keep in sync with
    /// `lib/services/watch_bridge_service.dart`.
    static let methodChannelName = "loadout/watch_bridge"

    /// EventChannel name for streaming inbound messages from the watch
    /// to Flutter.
    static let eventChannelName = "loadout/watch_bridge/events"

    private var methodChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Convenience entry point retained from the legacy
    /// `FlutterAppDelegate` pattern, where activation happened inside
    /// `didFinishLaunchingWithOptions` with the root view controller in
    /// hand. New code should prefer [activate(messenger:)] — it doesn't
    /// require pulling the controller out of the window hierarchy and
    /// works with both the implicit-engine pattern AND the legacy one.
    func activate(with controller: FlutterViewController) {
        activate(messenger: controller.binaryMessenger)
    }

    /// Activate the bridge on a known [FlutterBinaryMessenger]. This is
    /// the activation path used by the implicit-engine pattern in
    /// `AppDelegate.didInitializeImplicitFlutterEngine` — pulling a
    /// registrar out of `engineBridge.pluginRegistry` and forwarding
    /// `registrar.messenger()` here.
    func activate(messenger: FlutterBinaryMessenger) {
        guard let session else { return }
        // Idempotent — calling activate twice (e.g. if both the legacy
        // and implicit paths fire on a future Flutter SDK migration)
        // shouldn't double-register the channel handlers.
        guard methodChannel == nil else { return }

        session.delegate = self
        session.activate()

        let method = FlutterMethodChannel(
            name: Self.methodChannelName,
            binaryMessenger: messenger
        )
        method.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        self.methodChannel = method

        let event = FlutterEventChannel(
            name: Self.eventChannelName,
            binaryMessenger: messenger
        )
        event.setStreamHandler(self)
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isWatchPaired":
            result(session?.isPaired ?? false)
        case "isWatchAppInstalled":
            result(session?.isWatchAppInstalled ?? false)
        case "isReachable":
            result(session?.isReachable ?? false)
        case "send":
            guard let payload = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "send() expects Map<String,Object>",
                                    details: nil))
                return
            }
            send(payload)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        guard session.isReachable else {
            session.transferUserInfo(payload)
            return
        }
        session.sendMessage(payload, replyHandler: nil) { _ in }
    }

    private func emit(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }
}

extension WatchSessionBridge: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) { /* no-op */ }

    // Required iOS-only callbacks. They have to exist or `WCSession` will
    // crash on activation.
    func sessionDidBecomeInactive(_ session: WCSession) { /* no-op */ }
    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so subsequent paired watches still work.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        emit(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        emit(userInfo)
    }
}

extension WatchSessionBridge: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
