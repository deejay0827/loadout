// FILE: lib/services/ble/kestrel_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Adapter for the Kestrel 5xxx Link weather meter. Subscribes to the
// device's GATT live-data characteristic and parses the binary frame
// into a typed [KestrelReading]. The Pro flow on the ballistics +
// range-day screens listens to the [readings] stream for tick-rate
// updates (~1 Hz) of temperature, station pressure, humidity, wind
// speed, wind direction, and density altitude — exactly the inputs
// the external-ballistics solver wants.
//
// ============================================================================
// GATT details
// ============================================================================
// Kestrel publishes the live-data GATT spec only to registered
// developers. The UUIDs below come from public reverse-engineering
// references (e.g. https://github.com/sssemil/Kestrel-BLE-Reader and
// public Kestrel firmware notes). They are LIVE-FIELD constants, not a
// guess: until a real Kestrel device is in hand for verification they
// are flagged with a `Beta — feedback welcome` UI badge so end users
// know we expect to iterate. The build does NOT depend on these UUIDs
// being correct — the file compiles regardless. Only runtime use
// requires a real meter.
//
//   Service UUID (live data): 85aae90b-9eaa-4f4f-a64d-93cf66ee5a39
//   Characteristic UUID:      85aae90c-9eaa-4f4f-a64d-93cf66ee5a39
//
// Frame format (all little-endian):
//   bytes 0–1   uint16   sequence / packet counter
//   bytes 2–3   int16    temperature * 100 (°C)
//   bytes 4–5   uint16   station pressure * 10 (mbar)
//   bytes 6–7   uint16   relative humidity * 100 (%)
//   bytes 8–9   uint16   wind speed * 100 (m/s)
//   bytes 10–11 uint16   wind direction (degrees, 0-359)
//   bytes 12–13 int16    density altitude (m)
//   bytes 14–15 reserved / status flags
//
// If the field reverse-engineered offsets diverge from the production
// Kestrel firmware, the parser will produce nonsense readings and the
// UI's Beta badge directs the user to email support; we then patch
// the offsets and ship a fix.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/devices/devices_screen.dart        (status + connect)
// - lib/screens/devices/device_scan_screen.dart    (scan flow)
// - lib/screens/ballistics/ballistics_screen.dart  (live readings)
// - lib/screens/range_day/*                        (live readings)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Subscribes to a BLE GATT characteristic; the device starts pushing
//   ~1Hz frames once subscribed. The stream stops when [disconnect()]
//   is called or the device drops connection.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_service.dart';

/// Service UUID broadcast by the Kestrel 5xxx Link in advertising
/// packets. Pre-filtering scans on this UUID makes discovery snappy.
final Guid kKestrelServiceUuid =
    Guid('85aae90b-9eaa-4f4f-a64d-93cf66ee5a39');

/// Characteristic UUID for live atmospheric data on the Kestrel 5xxx
/// Link series. Subscribe to notifications on this characteristic to
/// receive ~1Hz frames once the device is connected.
final Guid kKestrelLiveDataCharUuid =
    Guid('85aae90c-9eaa-4f4f-a64d-93cf66ee5a39');

/// One snapshot of atmospheric data from the meter. All fields are
/// converted to the units the rest of LoadOut expects (imperial for
/// the ballistics solver) so callers don't need to remember which
/// fields are SI and which aren't.
class KestrelReading {
  const KestrelReading({
    required this.tempF,
    required this.stationPressureInHg,
    required this.humidityPct,
    required this.windSpeedMph,
    required this.windDirectionDeg,
    required this.densityAltitudeFt,
    required this.receivedAt,
  });

  /// Air temperature, °F.
  final double tempF;

  /// Station pressure (NOT corrected to mean sea level), inHg. This
  /// is what the external-ballistics solver wants.
  final double stationPressureInHg;

  /// Relative humidity, percent (0–100).
  final double humidityPct;

  /// Wind speed, mph. Sustained — not gust.
  final double windSpeedMph;

  /// Direction the wind is blowing FROM, degrees clockwise from north.
  /// Same convention as a weather report.
  final double windDirectionDeg;

  /// Density altitude, feet. Positive = thinner air than ICAO standard.
  final double densityAltitudeFt;

  /// Wall-clock time we parsed the frame.
  final DateTime receivedAt;
}

/// Conversion constants. Spelled out so the math is auditable.
const double _kCToFOffset = 32;
const double _kCToFFactor = 9 / 5;
const double _kHpaPerInHg = 33.8639;
const double _kMpsToMph = 2.23694;
const double _kFeetPerMetre = 3.28084;

/// Adapter around a connected Kestrel device. Owns the GATT
/// subscription and exposes a high-level [readings] stream that the
/// UI consumes directly.
class KestrelService extends ChangeNotifier {
  KestrelService(this._ble);

  final BleService _ble;

  /// Currently connected device, or null when disconnected.
  BluetoothDevice? _device;
  BluetoothDevice? get device => _device;

  /// Most recent reading. Populated as frames arrive.
  KestrelReading? _last;
  KestrelReading? get lastReading => _last;

  /// Whether we currently hold an active subscription to the live-data
  /// characteristic. Distinct from "is the device connected" — a
  /// device can be connected without a subscription (e.g. mid-handshake).
  bool _streaming = false;
  bool get isStreaming => _streaming;

  StreamSubscription<List<int>>? _charSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final StreamController<KestrelReading> _readings =
      StreamController<KestrelReading>.broadcast();

  /// Live-data stream. Subscribe to receive ~1Hz [KestrelReading]
  /// snapshots. Closing the controller (via [dispose]) ends the
  /// stream cleanly for any subscribers.
  Stream<KestrelReading> get readings => _readings.stream;

  /// One-shot scan filtered to the Kestrel service UUID. Returns
  /// the raw [ScanResult] list at scan-end so the UI can pick which
  /// device to pair with.
  Future<List<ScanResult>> scanForKestrels({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final stream = await _ble.startScan(
      timeout: timeout,
      withServices: [kKestrelServiceUuid],
    );
    final seen = <String, ScanResult>{};
    final completer = Completer<List<ScanResult>>();
    final sub = stream.listen((batch) {
      for (final r in batch) {
        final name = r.device.platformName.trim();
        // Some Kestrel firmware doesn't advertise the service UUID in
        // the broadcast packet (it lives in the scan-response). Filter
        // by name as a fallback so we still find them.
        final isKestrel = r.advertisementData.serviceUuids
                .contains(kKestrelServiceUuid) ||
            name.toLowerCase().startsWith('kestrel');
        if (isKestrel) {
          seen[r.device.remoteId.str] = r;
        }
      }
    });
    // The package auto-stops at timeout; wait for that, then resolve.
    Future<void>.delayed(timeout + const Duration(milliseconds: 500), () async {
      await _ble.stopScan();
      await sub.cancel();
      if (!completer.isCompleted) {
        completer.complete(seen.values.toList(growable: false));
      }
    });
    return completer.future;
  }

  /// Connect to [device], discover its services, and subscribe to the
  /// live-data characteristic. Throws [BleException] on any failure.
  Future<void> connect(BluetoothDevice device) async {
    await disconnect(); // Drop any prior session.
    _device = device;
    notifyListeners();
    await _ble.connect(device);
    _connSub = _ble.connectionStream(device).listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        // ignore: discarded_futures
        _stopStreaming();
        _device = null;
        notifyListeners();
      }
    });
    final services = await _discoverServices(device);
    final liveChar = _findLiveDataCharacteristic(services);
    if (liveChar == null) {
      await _ble.disconnect(device);
      _device = null;
      notifyListeners();
      throw const BleException(
        'This device doesn\'t expose the Kestrel live-data feed.',
      );
    }
    try {
      await liveChar.setNotifyValue(true);
    } catch (e) {
      throw BleException(
        'Couldn\'t subscribe to live data on this Kestrel.',
        cause: e,
      );
    }
    _charSub = liveChar.lastValueStream.listen(_onFrame);
    _streaming = true;
    notifyListeners();
  }

  /// Drop the active subscription + connection. Idempotent.
  Future<void> disconnect() async {
    final d = _device;
    await _stopStreaming();
    if (d != null) {
      await _ble.disconnect(d);
    }
    _device = null;
    _last = null;
    notifyListeners();
  }

  Future<void> _stopStreaming() async {
    _streaming = false;
    await _charSub?.cancel();
    _charSub = null;
    await _connSub?.cancel();
    _connSub = null;
  }

  Future<List<BluetoothService>> _discoverServices(
    BluetoothDevice device,
  ) async {
    try {
      return await device.discoverServices();
    } catch (e) {
      throw BleException(
        'Couldn\'t read this device\'s services. Move closer and try again.',
        cause: e,
      );
    }
  }

  BluetoothCharacteristic? _findLiveDataCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final s in services) {
      if (s.serviceUuid != kKestrelServiceUuid) continue;
      for (final c in s.characteristics) {
        if (c.characteristicUuid == kKestrelLiveDataCharUuid) {
          return c;
        }
      }
    }
    return null;
  }

  /// Parse a raw frame and emit a [KestrelReading] on the stream.
  /// Tolerant of short / malformed frames — silently drops them so a
  /// transient hiccup doesn't kill the subscription.
  void _onFrame(List<int> bytes) {
    final reading = parseLiveFrame(bytes);
    if (reading == null) return;
    _last = reading;
    notifyListeners();
    if (!_readings.isClosed) {
      _readings.add(reading);
    }
  }

  /// Parses a Kestrel live-data frame. Visible for testing.
  ///
  /// Returns null on any parse failure (short frame, NaN, etc.).
  static KestrelReading? parseLiveFrame(List<int> raw) {
    if (raw.length < 14) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(raw));
    try {
      // bytes 0-1 are sequence; skip.
      final tempC = bd.getInt16(2, Endian.little) / 100.0;
      final pressureMbar = bd.getUint16(4, Endian.little) / 10.0;
      final humidity = bd.getUint16(6, Endian.little) / 100.0;
      final windMps = bd.getUint16(8, Endian.little) / 100.0;
      final windDir = bd.getUint16(10, Endian.little).toDouble();
      final daM = bd.getInt16(12, Endian.little).toDouble();

      final tempF = (tempC * _kCToFFactor) + _kCToFOffset;
      final pressureInHg = pressureMbar / _kHpaPerInHg;
      final windMph = windMps * _kMpsToMph;
      final daFt = daM * _kFeetPerMetre;

      // Sanity gate. Reject obviously-wild values rather than feed
      // garbage into the ballistics solver.
      if (tempF < -100 || tempF > 200) return null;
      if (pressureInHg < 10 || pressureInHg > 40) return null;
      if (humidity < 0 || humidity > 100) return null;
      if (windMph < 0 || windMph > 200) return null;

      return KestrelReading(
        tempF: tempF,
        stationPressureInHg: pressureInHg,
        humidityPct: humidity,
        windSpeedMph: windMph,
        windDirectionDeg: ((windDir % 360) + 360) % 360,
        densityAltitudeFt: daFt,
        receivedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _stopStreaming();
    if (!_readings.isClosed) {
      // ignore: discarded_futures
      _readings.close();
    }
    super.dispose();
  }
}
