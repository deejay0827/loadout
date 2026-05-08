// FILE: lib/services/watch_bridge_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Phone-side facade for the Apple Watch + Wear OS companion apps.
//
// Wraps a [MethodChannel] (`loadout/watch_bridge`) and an
// [EventChannel] (`loadout/watch_bridge/events`). Native code on each
// platform implements the actual transport:
//
//   iOS:     ios/Runner/WatchSessionBridge.swift  (WatchConnectivity)
//   Android: android/app/src/main/kotlin/.../WatchBridge.kt
//            (Google Play Services Wearable Data Layer)
//
// The Dart layer is platform-agnostic — call `sendDope`, `sendActiveLoad`,
// `sendFirearmGlance`, listen on `incomingShots`, and the right thing
// happens on whichever device the user is paired to. Web / desktop /
// platforms without WatchConnectivity drop everything silently.
//
// Reserved paths (CLAUDE.md §15):
//
//   active_load     phone -> watch     ActiveLoadSnapshot
//   dope            phone -> watch     DopeSnapshot
//   firearm_glance  phone -> watch     FirearmGlanceSnapshot
//   log_shot        watch -> phone     ShotLogged
//   timer_event     watch <-> phone    TimerEvent
//
// Privacy: the bridge does not hit the network. All transport goes
// over Apple's WatchConnectivity (encrypted peer-to-peer) or Google's
// Wearable Data Layer (encrypted peer-to-peer). The phone never
// uploads watch payloads anywhere. See CLAUDE.md §13.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/watch_payloads.dart';

/// Connection state surfaced to the phone UI (an AppBar dot, the
/// Settings → Companion Apps screen, etc.). Mirrors what the platform
/// reports — no extra logic.
enum WatchConnectionState {
  /// Platform is web / macOS / Linux / Windows; bridge is a no-op.
  unsupported,

  /// Native side reports no paired watch.
  notPaired,

  /// Watch paired but companion app not installed.
  appNotInstalled,

  /// Companion app installed but unreachable (asleep / out of range).
  notReachable,

  /// Companion app is reachable in the foreground. Live messages OK.
  reachable,
}

/// Minimal stream-based facade for the watch bridge. Provided once at
/// the root via `Provider<WatchBridgeService>` and shared across the
/// app.
class WatchBridgeService {
  WatchBridgeService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isSupportedOverride,
  })  : _method = methodChannel ?? const MethodChannel(_kMethodChannelName),
        _event = eventChannel ?? const EventChannel(_kEventChannelName),
        _isSupported = isSupportedOverride ?? _kPlatformProbe {
    if (_isSupported) {
      _connection = ValueNotifier<WatchConnectionState>(
        WatchConnectionState.notPaired,
      );
      _shotsCtrl = StreamController<ShotLogged>.broadcast();
      _timerCtrl = StreamController<TimerEvent>.broadcast();
      _eventSub = _event.receiveBroadcastStream().listen(
            _onEvent,
            onError: (Object error) {
              // Native failures are best-effort; surface via debugPrint
              // but never crash the host app over the watch link.
              debugPrint('WatchBridgeService event error: $error');
            },
          );
      _refreshConnectionState();
    } else {
      _connection = ValueNotifier<WatchConnectionState>(
        WatchConnectionState.unsupported,
      );
      _shotsCtrl = StreamController<ShotLogged>.broadcast();
      _timerCtrl = StreamController<TimerEvent>.broadcast();
    }
  }

  static const String _kMethodChannelName = 'loadout/watch_bridge';
  static const String _kEventChannelName = 'loadout/watch_bridge/events';

  /// `true` only on the two platforms that have a native watch
  /// implementation. Everywhere else the bridge is a no-op.
  static final bool _kPlatformProbe = _detectSupport();

  static bool _detectSupport() {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS || Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  final MethodChannel _method;
  final EventChannel _event;
  final bool _isSupported;

  late final ValueNotifier<WatchConnectionState> _connection;
  late final StreamController<ShotLogged> _shotsCtrl;
  late final StreamController<TimerEvent> _timerCtrl;
  StreamSubscription<dynamic>? _eventSub;

  /// Observable connection state. Updates whenever the native side
  /// reports a paired-watch / reachability change.
  ValueListenable<WatchConnectionState> get connection => _connection;

  /// All `log_shot` messages from the watch.
  Stream<ShotLogged> get incomingShots => _shotsCtrl.stream;

  /// All `timer_event` messages from the watch (start/pause/expired/...).
  Stream<TimerEvent> get incomingTimerEvents => _timerCtrl.stream;

  /// True if the runtime supports a watch link (iOS or Android only).
  bool get isSupported => _isSupported;

  /// Shorthand for the UI: is the watch app installed and reachable
  /// right now?
  bool get isReachable => _connection.value == WatchConnectionState.reachable;

  /// Push the latest DOPE snapshot to the watch. Lossy — only the
  /// most recent matters, so we use `applicationContext` semantics on
  /// iOS and a stable-path DataItem on Android (replaces in place).
  Future<void> sendDope(DopeSnapshot snapshot) async {
    if (!_isSupported) return;
    if (snapshot.jsonByteSize > _kMaxPayloadBytes) {
      debugPrint(
        'WatchBridgeService: dope payload too large '
        '(${snapshot.jsonByteSize} > $_kMaxPayloadBytes); dropping.',
      );
      return;
    }
    await _send(WatchPaths.dope, snapshot.toJsonForWatch(), lossy: true);
  }

  /// Push the user's currently-selected recipe to the watch.
  Future<void> sendActiveLoad(ActiveLoadSnapshot snapshot) async {
    if (!_isSupported) return;
    await _send(
      WatchPaths.activeLoad,
      snapshot.toJsonForWatch(),
      lossy: true,
    );
  }

  /// Push the active firearm summary to the watch.
  Future<void> sendFirearmGlance(FirearmGlanceSnapshot snapshot) async {
    if (!_isSupported) return;
    await _send(
      WatchPaths.firearmGlance,
      snapshot.toJsonForWatch(),
      lossy: true,
    );
  }

  /// Force a refresh of [connection]. Called automatically on
  /// construction; call again from app lifecycle observers if needed.
  Future<void> refreshConnectionState() => _refreshConnectionState();

  Future<void> _refreshConnectionState() async {
    if (!_isSupported) return;
    try {
      final isPaired = await _method.invokeMethod<bool>('isWatchPaired') ?? false;
      if (!isPaired) {
        _connection.value = WatchConnectionState.notPaired;
        return;
      }
      final isInstalled =
          await _method.invokeMethod<bool>('isWatchAppInstalled') ?? false;
      if (!isInstalled) {
        _connection.value = WatchConnectionState.appNotInstalled;
        return;
      }
      final isReachable =
          await _method.invokeMethod<bool>('isReachable') ?? false;
      _connection.value = isReachable
          ? WatchConnectionState.reachable
          : WatchConnectionState.notReachable;
    } catch (e) {
      debugPrint('WatchBridgeService: refresh state error $e');
      _connection.value = WatchConnectionState.notPaired;
    }
  }

  Future<void> _send(
    String path,
    Map<String, Object?> payload, {
    required bool lossy,
  }) async {
    try {
      await _method.invokeMethod<void>('send', <String, Object?>{
        'path': path,
        'payload': payload,
        'lossy': lossy,
      });
    } on MissingPluginException {
      // Native side not wired yet (e.g. iOS without the watch target
      // added in Xcode). Silently drop — the app stays usable.
    } on PlatformException catch (e) {
      debugPrint('WatchBridgeService.send($path) error: ${e.message}');
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    // Channel codec gives us Map<dynamic, dynamic> — coerce key/value
    // shapes once at the boundary.
    final map = Map<String, Object?>.from(
      raw.map((k, v) => MapEntry(k.toString(), v)),
    );
    final path = map['path'] as String?;
    if (path == null) {
      // The native side may also forward connection-state changes
      // through the event channel as `{state: 'reachable'}`. Apply
      // those if present.
      final state = map['state'] as String?;
      if (state != null) {
        _connection.value = _stateFromString(state);
      }
      return;
    }
    final payloadRaw = map['payload'];
    if (payloadRaw is! Map) return;
    final payload = Map<String, Object?>.from(
      payloadRaw.map((k, v) => MapEntry(k.toString(), v)),
    );
    switch (path) {
      case WatchPaths.logShot:
        _shotsCtrl.add(ShotLogged.fromWatchJson(payload));
        break;
      case WatchPaths.timerEvent:
        _timerCtrl.add(TimerEvent.fromWatchJson(payload));
        break;
      default:
        // Unknown path — ignore. Future paths can land without
        // crashing existing builds.
        break;
    }
  }

  WatchConnectionState _stateFromString(String s) {
    switch (s) {
      case 'reachable':
        return WatchConnectionState.reachable;
      case 'notReachable':
        return WatchConnectionState.notReachable;
      case 'appNotInstalled':
        return WatchConnectionState.appNotInstalled;
      case 'notPaired':
        return WatchConnectionState.notPaired;
      case 'unsupported':
      default:
        return WatchConnectionState.unsupported;
    }
  }

  /// Best-effort dispose; rarely called because the bridge lives for
  /// the app's lifetime.
  void dispose() {
    _eventSub?.cancel();
    _shotsCtrl.close();
    _timerCtrl.close();
  }

  /// Hard cap mirroring WatchConnectivity / Wearable Data Layer
  /// guidance. Both platforms accept much larger payloads in theory,
  /// but smaller-is-better for the lossy `applicationContext` path.
  /// 16 KiB leaves room for the StandardMethodCodec envelope on top of
  /// the JSON content size.
  static const int _kMaxPayloadBytes = 16 * 1024;
}
