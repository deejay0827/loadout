// FILE: lib/services/ble/ble_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Thin platform-abstraction layer over `flutter_blue_plus`. Wraps the
// global `FlutterBluePlus` singleton in a small instance API the rest of
// the app actually wants to talk to:
//
//   - `ensurePermissions()` — request the runtime permissions BLE needs
//     (Android 12+ split BLUETOOTH_SCAN / BLUETOOTH_CONNECT, iOS handled
//     automatically by Info.plist usage strings; macOS needs the
//     `com.apple.security.device.bluetooth` entitlement to be present).
//   - `isAvailable()` — reports whether Bluetooth is supported at all on
//     the current device + platform combination. Surfaces a friendly
//     "Bluetooth not available on this device" copy upstream when this
//     returns false.
//   - `adapterState` / `currentAdapterState` — observed Bluetooth radio
//     state. Lets the UI gate on "is the radio on?" without falling
//     through to a confusing scan-with-no-results.
//   - `startScan()` / `stopScan()` — wraps the scanning APIs with sane
//     defaults (12 second timeout, optional service-UUID filter so
//     discovery is fast on devices that broadcast known UUIDs like the
//     Kestrel weather meter).
//   - `connect()` / `disconnect()` — wraps the connect calls and surfaces
//     errors as `BleException`s the UI can display verbatim.
//   - `connectionStream()` — re-exposes a device's connection state stream
//     so the UI can stop / start subscriptions in lock-step with
//     reconnects.
//
// All async methods either succeed or throw `BleException` with a
// user-friendly `userMessage`. The UI never has to peer at platform
// channel exceptions.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Two device adapters depend on this:
//
//   - `lib/services/ble/kestrel_service.dart` — Kestrel 5xxx Link weather
//     meter, drives the live atmospheric data stream into the ballistics
//     calculator and range-day Environment sections.
//   - `lib/services/ble/garmin_xero_service.dart` — placeholder for the
//     Garmin Xero C1 Pro chronograph; the v1 path is .fit file import,
//     but a future direct-BLE pull will live alongside this service.
//
// Centralizing permission + scan + connect in one place means each
// device adapter focuses solely on the GATT-specific side of its job
// (which characteristic to subscribe to, how to parse the bytes).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/services/ble/kestrel_service.dart
// - lib/services/ble/garmin_xero_service.dart (future direct-BLE path)
// - lib/screens/devices/devices_screen.dart
// - lib/screens/devices/device_scan_screen.dart
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - `ensurePermissions()` may pop OS permission dialogs.
// - `startScan()` activates the Bluetooth radio; the scan auto-stops at
//   the timeout you pass.
// - `connect()` keeps a live connection open until you call
//   `disconnect()`. The OS may clean up if the device disappears.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// User-facing BLE failure. Thrown by [BleService] methods so the UI
/// can present a friendly snackbar verbatim from [userMessage].
class BleException implements Exception {
  const BleException(this.userMessage, {this.cause});

  /// Friendly, short, end-user-readable failure text.
  final String userMessage;

  /// Underlying error (if any). Diagnostic only — never shown to user.
  final Object? cause;

  @override
  String toString() =>
      'BleException($userMessage)${cause == null ? '' : ' caused by $cause'}';
}

/// Outcome of an [BleService.ensurePermissions] call. Carries enough
/// information for the UI to either proceed, show a soft "we still
/// need…" hint, or deep-link the user to system settings when a
/// permission was denied permanently.
class BlePermissionResult {
  const BlePermissionResult({
    required this.granted,
    required this.permanentlyDenied,
  });

  /// Convenience constant for the all-good path.
  static const ok = BlePermissionResult(
    granted: true,
    permanentlyDenied: false,
  );

  /// True iff every required permission resolved to granted.
  final bool granted;

  /// True iff at least one required permission was denied with the
  /// "don't ask again" / iOS Settings-only flag set. The UI should
  /// surface an "Open Settings" button instead of retrying.
  final bool permanentlyDenied;
}

/// Cross-platform BLE service. Single instance, provided once via
/// `Provider<BleService>` at the app root. Stateless beyond what
/// `flutter_blue_plus` already keeps internally, so creating two
/// instances is harmless but pointless.
class BleService extends ChangeNotifier {
  BleService();

  /// Expose the package's adapter-state stream so the devices screen
  /// can listen and live-update its "Bluetooth is off" banner.
  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  /// Last-known adapter state. Updated lazily as
  /// [FlutterBluePlus.adapterState] emits.
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  BluetoothAdapterState get currentAdapterState => _adapterState;

  /// Stream of in-flight scan results. Re-emits [ScanResult] lists each
  /// time a new device is discovered (or an existing device's RSSI
  /// updates). Consumers should `take(...)` or close the subscription
  /// when their UI tears down.
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  /// Whether a scan is currently active. Mirrors the package's flag.
  bool get isScanning => FlutterBluePlus.isScanningNow;

  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  bool _initialized = false;

  /// Wires up the adapter-state subscription and grabs whatever the OS
  /// last reported. Call this once during provider construction. Safe
  /// to invoke more than once — it is a no-op after the first call.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!await isAvailable()) return;
    try {
      _adapterState = await FlutterBluePlus.adapterState.first
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Some platforms / permission states never emit synchronously;
      // fall back to the default `unknown` and trust the stream
      // listener below to backfill.
    }
    _adapterStateSub = FlutterBluePlus.adapterState.listen((s) {
      _adapterState = s;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _adapterStateSub?.cancel();
    super.dispose();
  }

  /// Whether the platform supports Bluetooth Low Energy at all. Returns
  /// false on:
  ///   - desktop Linux (we don't ship a Linux build today),
  ///   - Web (no flutter_blue_plus_web yet at the version we depend on),
  ///   - any platform that throws when the package's `isSupported`
  ///     getter is invoked.
  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    if (!(Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS)) {
      return false;
    }
    try {
      return await FlutterBluePlus.isSupported;
    } catch (_) {
      return false;
    }
  }

  /// Convenience boolean: Bluetooth radio currently powered on.
  bool get isAdapterOn => _adapterState == BluetoothAdapterState.on;

  /// Request the runtime permissions BLE scanning + connecting needs.
  ///
  /// On iOS, the OS prompt fires automatically the first time we call
  /// into the platform channel — `permission_handler` returns
  /// `granted` for `Permission.bluetooth` immediately on iOS once the
  /// system prompt has been answered, so this method is a no-op there
  /// today. On Android 12+ (API 31+), we have to request
  /// `Permission.bluetoothScan` and `Permission.bluetoothConnect`
  /// separately. On older Android (≤30), the legacy
  /// `Permission.bluetooth` covers both.
  Future<BlePermissionResult> ensurePermissions() async {
    if (kIsWeb) {
      return const BlePermissionResult(
        granted: false,
        permanentlyDenied: false,
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      // iOS / macOS surface their own prompt via NSBluetooth*UsageDescription;
      // permission_handler returns granted once the user has answered.
      // On macOS the entitlement gate happens at app-launch.
      return BlePermissionResult.ok;
    }
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      final granted = scan.isGranted && connect.isGranted;
      final permanentlyDenied =
          scan.isPermanentlyDenied || connect.isPermanentlyDenied;
      return BlePermissionResult(
        granted: granted,
        permanentlyDenied: permanentlyDenied,
      );
    }
    return const BlePermissionResult(
      granted: false,
      permanentlyDenied: false,
    );
  }

  /// Open the OS's app-settings screen so the user can grant a
  /// permanently-denied permission. Returns true on success, false if
  /// the platform refused.
  Future<bool> openAppSettingsPage() => openAppSettings();

  /// Start a scan. Returns the package's [scanResults] stream for
  /// convenience. Auto-stops after [timeout]. Pass a list of GATT
  /// service UUIDs in [withServices] to filter at the OS level — much
  /// faster on devices like Kestrel that advertise a known service.
  ///
  /// Throws [BleException] if the radio is off or the permissions
  /// haven't been granted.
  Future<Stream<List<ScanResult>>> startScan({
    Duration timeout = const Duration(seconds: 12),
    List<Guid>? withServices,
  }) async {
    if (!await isAvailable()) {
      throw const BleException(
        'Bluetooth is not available on this device.',
      );
    }
    final perm = await ensurePermissions();
    if (!perm.granted) {
      throw BleException(
        perm.permanentlyDenied
            ? 'Bluetooth permission is denied. Open Settings to enable.'
            : 'Bluetooth permission is required to scan for devices.',
      );
    }
    if (!isAdapterOn) {
      throw const BleException(
        'Bluetooth is turned off. Turn it on to scan for devices.',
      );
    }
    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: withServices ?? const [],
        androidUsesFineLocation: false,
      );
    } catch (e) {
      throw BleException(
        'Couldn\'t start a Bluetooth scan. Try again.',
        cause: e,
      );
    }
    return FlutterBluePlus.scanResults;
  }

  /// Stop any in-flight scan. Idempotent: safe to call when no scan is
  /// running.
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Stopping a not-running scan is fine — silently ignore.
    }
  }

  /// Connect to [device]. Throws [BleException] on failure.
  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
    } catch (e) {
      throw BleException(
        'Couldn\'t connect to ${_friendlyName(device)}.',
        cause: e,
      );
    }
  }

  /// Drop a connection. Idempotent: silently ignores "already
  /// disconnected" errors.
  Future<void> disconnect(BluetoothDevice device) async {
    try {
      await device.disconnect();
    } catch (_) {
      // Already disconnected — fine.
    }
  }

  /// Per-device connection-state stream. Useful for UIs that want to
  /// flip a status indicator between "connecting / connected /
  /// disconnected" without polling.
  Stream<BluetoothConnectionState> connectionStream(BluetoothDevice d) =>
      d.connectionState;

  /// Best-effort friendly name. Some devices broadcast an empty name
  /// (only the MAC / UUID is exposed); fall through to a short prefix
  /// of the remote-id so the user has something to read.
  String _friendlyName(BluetoothDevice d) {
    final n = d.platformName.trim();
    if (n.isNotEmpty) return n;
    final id = d.remoteId.str;
    return id.length > 8 ? '${id.substring(0, 8)}…' : id;
  }
}
