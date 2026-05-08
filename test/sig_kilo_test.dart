// Smoke tests for the Sig Sauer KILO BDX range frame parser. The exact
// byte layout requires a real KILO for end-to-end validation, but we
// can at least confirm the parser:
//   - returns null on truncated frames,
//   - returns null on the wrong message-type marker,
//   - rejects frames whose XOR checksum doesn't match (when present),
//   - converts yards / metres frames the same way and stays within
//     physical sanity bounds.
//
// The reference frame layout (see lib/services/ble/sig_kilo_service.dart):
//   byte 0       0xA1   message type marker (range)
//   byte 1       uint8  unit flag: 0 = yards, 1 = metres
//   bytes 2–3    uint16 LOS range (in declared unit, little-endian)
//   bytes 4–5    int16  incline angle * 10 (degrees, little-endian)
//   bytes 6–7    uint16 incline-corrected range (in declared unit)
//   byte 8       uint8  status flags
//   byte 9       uint8  XOR checksum of bytes 0..8

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ble/sig_kilo_service.dart';

/// Build a 10-byte BDX range frame with the right XOR checksum so the
/// parser accepts it. Distance units (yd vs m) are explicit on byte 1.
Uint8List _buildBdxFrame({
  required int unitFlag,
  required int losRaw,
  int angleTenthDeg = 0,
  int icRangeRaw = 0,
  int statusByte = 0,
}) {
  final bd = ByteData(10);
  bd.setUint8(0, 0xA1);
  bd.setUint8(1, unitFlag);
  bd.setUint16(2, losRaw, Endian.little);
  bd.setInt16(4, angleTenthDeg, Endian.little);
  bd.setUint16(6, icRangeRaw, Endian.little);
  bd.setUint8(8, statusByte);
  // Compute XOR over bytes 0..8.
  var xor = 0;
  for (var i = 0; i < 9; i++) {
    xor ^= bd.getUint8(i);
  }
  bd.setUint8(9, xor & 0xFF);
  return bd.buffer.asUint8List();
}

void main() {
  group('SigKiloService.parseBdxFrame', () {
    test('returns null on short / empty frames', () {
      expect(SigKiloService.parseBdxFrame(<int>[]), isNull);
      expect(SigKiloService.parseBdxFrame(const [0xA1, 0x00, 0x10]), isNull);
    });

    test('returns null when message-type marker is not 0xA1', () {
      // 0xB0 is "config" in some BDX firmware revisions — must skip.
      final bd = ByteData(10);
      bd.setUint8(0, 0xB0);
      bd.setUint8(1, 0x00);
      bd.setUint16(2, 600, Endian.little);
      expect(
        SigKiloService.parseBdxFrame(bd.buffer.asUint8List()),
        isNull,
      );
    });

    test('parses a yards frame and exposes both yd + m', () {
      final raw = _buildBdxFrame(unitFlag: 0, losRaw: 612);
      final r = SigKiloService.parseBdxFrame(raw);
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(612, 0.5));
      // 612 yd ≈ 559.5 m
      expect(r.rangeM, closeTo(559.5, 0.5));
    });

    test('parses a metres frame and converts to yards', () {
      final raw = _buildBdxFrame(unitFlag: 1, losRaw: 500);
      final r = SigKiloService.parseBdxFrame(raw);
      expect(r, isNotNull);
      expect(r!.rangeM, closeTo(500, 0.5));
      // 500 m ≈ 546.8 yd
      expect(r.rangeYd, closeTo(546.8, 0.5));
    });

    test('parses incline angle and incline-corrected range', () {
      // 12.5° up, 600yd LOS, 586yd shoot-to.
      final raw = _buildBdxFrame(
        unitFlag: 0,
        losRaw: 600,
        angleTenthDeg: 125,
        icRangeRaw: 586,
      );
      final r = SigKiloService.parseBdxFrame(raw);
      expect(r, isNotNull);
      expect(r!.angleDeg, closeTo(12.5, 0.05));
      expect(r.inclineCorrectedRangeYd, closeTo(586, 0.5));
      expect(r.hasIncline, isTrue);
    });

    test('rejects a frame whose XOR checksum is wrong', () {
      final raw = _buildBdxFrame(unitFlag: 0, losRaw: 800);
      // Corrupt the checksum byte.
      raw[9] = (raw[9] ^ 0xFF) & 0xFF;
      expect(SigKiloService.parseBdxFrame(raw), isNull);
    });

    test('rejects out-of-range distances', () {
      // 20,000 yd is outside the KILO line's physical envelope.
      final raw = _buildBdxFrame(unitFlag: 0, losRaw: 20000);
      expect(SigKiloService.parseBdxFrame(raw), isNull);
    });

    test('drops insane angle but keeps the range', () {
      // 200° is bogus — angle should be dropped, range still returned.
      final raw = _buildBdxFrame(
        unitFlag: 0,
        losRaw: 400,
        angleTenthDeg: 2000,
      );
      final r = SigKiloService.parseBdxFrame(raw);
      expect(r, isNotNull);
      expect(r!.rangeYd, closeTo(400, 0.5));
      expect(r.angleDeg, isNull);
    });
  });
}
