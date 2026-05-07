// Smoke tests for the Garmin Xero .fit parser. We don't have a real
// Xero session export available, so these only verify the parser
// handles bad input gracefully — empty bytes, garbage, FIT-magic but
// no velocity records. The intended runtime contract is "throw
// GarminXeroParseException with user-friendly text on any failure
// path; never crash the import button".

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ble/garmin_xero_service.dart';

void main() {
  group('GarminXeroService.parseFitBytes', () {
    test('throws on empty input', () {
      expect(
        () => GarminXeroService.parseFitBytes(<int>[]),
        throwsA(isA<GarminXeroParseException>()),
      );
    });

    test('throws on non-FIT bytes', () {
      expect(
        () => GarminXeroService.parseFitBytes(List.filled(64, 0xAA)),
        throwsA(isA<GarminXeroParseException>()),
      );
    });

    test('throws on FIT magic but no velocity records', () {
      // Header: size 14, proto 0x10, profile 0, datasize 0, ".FIT" magic.
      final fakeFit = <int>[
        14, 0x10, 0, 0,
        0, 0, 0, 0,
        0x2E, 0x46, 0x49, 0x54,
        0, 0,
      ];
      expect(
        () => GarminXeroService.parseFitBytes(fakeFit),
        throwsA(isA<GarminXeroParseException>()),
      );
    });
  });
}
