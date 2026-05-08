// Smoke tests for the Vortex Razor HD 4000 / Fury HD AB range frame
// parser. The frame is reverse-engineered and uses BIG-endian byte
// order — different from Sig BDX (little-endian). Get this wrong and
// distances explode by orders of magnitude.
//
// Reference frame layout (see lib/services/ble/vortex_rangefinder_service.dart):
//   byte 0       0x56 ('V') marker
//   byte 1       uint8  unit flag: 0 = yards, 1 = metres
//   bytes 2–3    uint16 LOS range (declared unit, BIG-endian)
//   bytes 4–5    int16  incline angle * 10 (degrees, big-endian)
//   bytes 6–7    uint16 incline-corrected range (declared unit)
//   byte 8       uint8  status / target-quality flags

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ble/vortex_rangefinder_service.dart';

void main() {
  group('VortexRangefinderService.parseVortexFrame', () {
    test('returns null on short / empty frames', () {
      expect(
        VortexRangefinderService.parseVortexFrame(<int>[]),
        isNull,
      );
      expect(
        VortexRangefinderService.parseVortexFrame(const [0x56, 0x00]),
        isNull,
      );
    });

    test("returns null when the 'V' marker is missing", () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x42); // not 0x56
      bd.setUint8(1, 0);
      bd.setUint16(2, 600, Endian.big);
      expect(
        VortexRangefinderService.parseVortexFrame(bd.buffer.asUint8List()),
        isNull,
      );
    });

    test('parses a yards frame (Razor HD 4000)', () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x56);
      bd.setUint8(1, 0); // yards
      bd.setUint16(2, 1234, Endian.big);
      bd.setInt16(4, 0, Endian.big); // angle 0
      bd.setUint16(6, 0, Endian.big); // no IC range
      bd.setUint8(8, 0);
      final r = VortexRangefinderService.parseVortexFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(1234, 0.5));
      // 1234 yd ≈ 1128.5 m
      expect(r.rangeM, closeTo(1128.5, 0.5));
      // 0° angle should still surface as 0.0, not null — the parser
      // only nulls when the value falls outside [-90, 90].
      expect(r.angleDeg, closeTo(0, 0.05));
    });

    test('parses a metres frame (Fury HD AB)', () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x56);
      bd.setUint8(1, 1); // metres
      bd.setUint16(2, 800, Endian.big);
      bd.setInt16(4, 75, Endian.big); // 7.5° up
      bd.setUint16(6, 793, Endian.big); // shoot-to 793 m
      bd.setUint8(8, 0);
      final r = VortexRangefinderService.parseVortexFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.rangeM, closeTo(800, 0.5));
      // 800 m ≈ 874.9 yd
      expect(r.rangeYd, closeTo(874.9, 0.5));
      expect(r.angleDeg, closeTo(7.5, 0.05));
      // 793 m ≈ 867.2 yd
      expect(r.inclineCorrectedRangeYd, closeTo(867.2, 0.5));
    });

    test('decodes a negative angle (downhill)', () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x56);
      bd.setUint8(1, 0);
      bd.setUint16(2, 500, Endian.big);
      bd.setInt16(4, -120, Endian.big); // -12.0°
      bd.setUint16(6, 488, Endian.big);
      bd.setUint8(8, 0);
      final r = VortexRangefinderService.parseVortexFrame(
        bd.buffer.asUint8List(),
      );
      expect(r, isNotNull);
      expect(r!.angleDeg, closeTo(-12, 0.05));
    });

    test('rejects an out-of-range unit flag', () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x56);
      bd.setUint8(1, 0x07); // not 0 or 1
      bd.setUint16(2, 500, Endian.big);
      expect(
        VortexRangefinderService.parseVortexFrame(bd.buffer.asUint8List()),
        isNull,
      );
    });

    test('rejects an absurd distance (10,000 yd is outside envelope)', () {
      final bd = ByteData(9);
      bd.setUint8(0, 0x56);
      bd.setUint8(1, 0);
      bd.setUint16(2, 10000, Endian.big);
      expect(
        VortexRangefinderService.parseVortexFrame(bd.buffer.asUint8List()),
        isNull,
      );
    });

    test('uses big-endian — not little — for the LOS range', () {
      // 0x02 0x58 in BE = 600. In LE it would be 22530, which would
      // fail the sanity gate. This test fails if the parser flips
      // endianness by mistake.
      final raw = Uint8List.fromList(
        <int>[0x56, 0x00, 0x02, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00],
      );
      final r = VortexRangefinderService.parseVortexFrame(raw);
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(600, 0.5));
    });
  });
}
