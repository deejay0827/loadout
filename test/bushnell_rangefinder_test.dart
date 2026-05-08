// Smoke tests for the Bushnell rangefinder range frame parser. The
// exact byte layout is reverse-engineered and varies subtly across
// product generations, so the parser is permissive: it accepts both a
// "0x42 prefix + unit + LOS + flags" layout (Forge / Engage / Elite)
// and a "unit + LOS + flags" layout where the prefix byte is absent
// (Phantom 2 / older firmware). Neither layout has a checksum.
//
// Reference frame layout (see lib/services/ble/bushnell_rangefinder_service.dart):
//   byte 0       0x42   'B' marker (sometimes absent on older devices)
//   byte 1       uint8  unit flag: 0 = yards, 1 = metres
//   bytes 2–3    uint16 LOS range (declared unit, little-endian)
//   byte 4       uint8  optional incline / status flags
//
// We exercise the same layout twice: once with the 'B' prefix and once
// without, to confirm the parser sniffs both and produces the same
// reading.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ble/bushnell_rangefinder_service.dart';

void main() {
  group('BushnellRangefinderService.parseBushnellFrame', () {
    test('returns null on short frames', () {
      expect(
        BushnellRangefinderService.parseBushnellFrame(<int>[]),
        isNull,
      );
      expect(
        BushnellRangefinderService.parseBushnellFrame(const [0x42]),
        isNull,
      );
    });

    test('parses a yards frame with the 0x42 prefix', () {
      // 0x42 'B', unit=0 (yd), LOS=420, flags=0xFF (no incline).
      final bd = ByteData(5);
      bd.setUint8(0, 0x42);
      bd.setUint8(1, 0); // yards
      bd.setUint16(2, 420, Endian.little);
      bd.setUint8(4, 0xFF);
      final r = BushnellRangefinderService.parseBushnellFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(420, 0.5));
      // 420 yd ≈ 384 m
      expect(r.rangeM, closeTo(384, 0.5));
      // 0xFF = "no incline"
      expect(r.angleDeg, isNull);
    });

    test('parses a yards frame WITHOUT the 0x42 prefix', () {
      // unit=0 (yd), LOS=420, flags=0xFF.
      final bd = ByteData(4);
      bd.setUint8(0, 0); // yards
      bd.setUint16(1, 420, Endian.little);
      bd.setUint8(3, 0xFF);
      final r = BushnellRangefinderService.parseBushnellFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(420, 0.5));
    });

    test('parses a metres frame and converts to yards', () {
      // 0x42 'B', unit=1 (m), LOS=200, flags=0xFF.
      final bd = ByteData(5);
      bd.setUint8(0, 0x42);
      bd.setUint8(1, 1); // metres
      bd.setUint16(2, 200, Endian.little);
      bd.setUint8(4, 0xFF);
      final r = BushnellRangefinderService.parseBushnellFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.rangeM, closeTo(200, 0.5));
      // 200 m ≈ 218.7 yd
      expect(r.rangeYd, closeTo(218.7, 0.5));
    });

    test('decodes a positive incline byte (Forge-style frame)', () {
      // 0x42 'B', unit=0 (yd), LOS=600, flags=10° up.
      final bd = ByteData(5);
      bd.setUint8(0, 0x42);
      bd.setUint8(1, 0);
      bd.setUint16(2, 600, Endian.little);
      bd.setUint8(4, 10);
      final r = BushnellRangefinderService.parseBushnellFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.angleDeg, closeTo(10, 0.5));
    });

    test('decodes a negative incline byte (downhill, two\'s complement)', () {
      // 0x42 'B', unit=0 (yd), LOS=600, flags=-15° (=> 0xF1 = 241).
      final bd = ByteData(5);
      bd.setUint8(0, 0x42);
      bd.setUint8(1, 0);
      bd.setUint16(2, 600, Endian.little);
      bd.setUint8(4, 0xF1); // -15
      final r = BushnellRangefinderService.parseBushnellFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.angleDeg, closeTo(-15, 0.5));
    });

    test('rejects an obviously-invalid unit flag', () {
      // unit=0x42 in a no-prefix frame would otherwise be ambiguous, so
      // the parser rejects unit values that aren't 0 or 1.
      final bd = ByteData(4);
      bd.setUint8(0, 0x07); // not 0 or 1
      bd.setUint16(1, 200, Endian.little);
      bd.setUint8(3, 0);
      expect(
        BushnellRangefinderService.parseBushnellFrame(
          bd.buffer.asUint8List(),
        ),
        isNull,
      );
    });

    test('rejects out-of-range distances', () {
      // 5000 yd is outside the Bushnell line's physical envelope.
      final bd = ByteData(5);
      bd.setUint8(0, 0x42);
      bd.setUint8(1, 0);
      bd.setUint16(2, 5000, Endian.little);
      bd.setUint8(4, 0xFF);
      expect(
        BushnellRangefinderService.parseBushnellFrame(
          bd.buffer.asUint8List(),
        ),
        isNull,
      );
    });
  });
}
