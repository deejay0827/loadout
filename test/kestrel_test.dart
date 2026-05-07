// Smoke tests for the Kestrel live-data frame parser. The exact byte
// layout requires a real meter to verify end-to-end, but we can at
// least confirm the parser:
//   - returns null on truncated frames,
//   - rejects values outside physical sanity bounds,
//   - converts SI inputs to imperial units the rest of LoadOut uses.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ble/kestrel_service.dart';

void main() {
  group('KestrelService.parseLiveFrame', () {
    test('returns null on short frames', () {
      expect(KestrelService.parseLiveFrame(<int>[]), isNull);
      expect(KestrelService.parseLiveFrame(List.filled(10, 0)), isNull);
    });

    test('parses a sane frame and converts to imperial', () {
      // Build a frame with 20°C, 1013.0 mbar, 50.00% RH, 5.00 m/s,
      // 270° from west, 100m density altitude.
      final bd = ByteData(16);
      bd.setUint16(0, 1, Endian.little); // sequence
      bd.setInt16(2, 2000, Endian.little); // 20.00 °C * 100
      bd.setUint16(4, 10130, Endian.little); // 1013.0 mbar * 10
      bd.setUint16(6, 5000, Endian.little); // 50.00% RH * 100
      bd.setUint16(8, 500, Endian.little); // 5.00 m/s * 100
      bd.setUint16(10, 270, Endian.little); // 270°
      bd.setInt16(12, 100, Endian.little); // 100m DA
      bd.setUint16(14, 0, Endian.little); // reserved
      final r = KestrelService.parseLiveFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      // 20°C → 68°F
      expect(r!.tempF, closeTo(68, 0.5));
      // 1013 mbar / 33.86 ≈ 29.91 inHg
      expect(r.stationPressureInHg, closeTo(29.91, 0.05));
      expect(r.humidityPct, closeTo(50, 0.5));
      // 5 m/s ≈ 11.18 mph
      expect(r.windSpeedMph, closeTo(11.18, 0.2));
      expect(r.windDirectionDeg, closeTo(270, 0.5));
      // 100 m ≈ 328 ft
      expect(r.densityAltitudeFt, closeTo(328.08, 0.5));
    });

    test('rejects out-of-range temperature', () {
      final bd = ByteData(16);
      bd.setInt16(2, 30000, Endian.little); // 300°C — bogus
      bd.setUint16(4, 10130, Endian.little);
      bd.setUint16(6, 5000, Endian.little);
      bd.setUint16(8, 500, Endian.little);
      bd.setUint16(10, 90, Endian.little);
      bd.setInt16(12, 0, Endian.little);
      expect(
        KestrelService.parseLiveFrame(bd.buffer.asUint8List()),
        isNull,
      );
    });
  });
}
