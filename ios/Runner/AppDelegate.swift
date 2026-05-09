import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Activate the watch-companion bridge as soon as the engine has a
    // plugin registry. The implicit-engine pattern doesn't surface a
    // FlutterViewController here (the window hierarchy is built later
    // by Flutter), so we go through `pluginRegistry.registrar(forPlugin:)`
    // to obtain a binary messenger. The plugin name is just a registry
    // scope — there's no real plugin behind it. See
    // `WatchSessionBridge.swift` for the matching activation site.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WatchSessionBridge") {
      WatchSessionBridge.shared.activate(messenger: registrar.messenger())
    }
  }
}
