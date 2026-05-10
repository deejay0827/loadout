// FILE: test/sight_calibration_test.dart
//
// Coverage for the Drop-Per-Click (DPC) sight calibration service.
//
// Pattern: pretend the user dialed exactly 10 mil up at 100 yd against a
// 24" tall reference target. Construct synthetic impact coords that would
// land at a known fraction of the dialed elevation. The derived scale
// must match the implanted scale within tight tolerance.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/ballistics/units.dart' as bu;
import 'package:loadout/services/scope_tracking_service.dart';

const _service = ScopeTrackingService();

void main() {
  group('Sight calibration — vertical', () {
    test('synthetic impacts at exactly 0.973× of dialed elevation '
        'recover the implanted scale', () {
      // Test target: 24" wide × 24" tall, at 100 yd.
      // Aim point: bottom of the target (Y = -1 in normalized coords).
      const targetWidthIn = 24.0;
      const targetHeightIn = 24.0;
      const distYd = 100.0;
      // User dials 10 mil up. At 100 yd that's 36" of commanded
      // elevation (1 mil = 3.6" / 100 yd).
      const advertisedDialMil = 10.0;
      // The implanted "true" scale: the scope tracks 0.973× advertised.
      const trueScale = 0.973;
      // Where the impacts should LAND on the target, in inches above
      // aim. Aim is -1 norm = -12" from center. Centroid impact = aim +
      // commanded × true_scale = -12 + 36 × 0.973 = -12 + 35.028 =
      // +23.028" from center → norm Y = +23.028 / 12 = ~1.919.
      const expectedCentroidIn = -12.0 + 36.0 * trueScale; // +23.028
      const expectedCentroidNorm = expectedCentroidIn / 12.0;
      // Build 5 impacts clustered tightly around that centroid (small
      // group ~0.1" 1-σ).
      final impacts = <ScopeTrackingObservation>[
        ScopeTrackingObservation(
            impactX: 0, impactY: expectedCentroidNorm + 0.005),
        ScopeTrackingObservation(
            impactX: 0, impactY: expectedCentroidNorm - 0.005),
        ScopeTrackingObservation(
            impactX: 0, impactY: expectedCentroidNorm + 0.0025),
        ScopeTrackingObservation(
            impactX: 0, impactY: expectedCentroidNorm - 0.0025),
        ScopeTrackingObservation(
            impactX: 0, impactY: expectedCentroidNorm),
      ];

      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: -1.0, // bottom of the target
        advertisedDialMil: advertisedDialMil,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: distYd,
        observations: impacts,
      );

      expect(result.derivedScale, closeTo(trueScale, 0.005),
          reason: 'derived scale should match the implanted 0.973 '
              'within 0.005');
      expect(result.observations.length, 5);
    });

    test('a perfectly-tracking scope returns scale ≈ 1.0', () {
      const targetWidthIn = 24.0;
      const targetHeightIn = 24.0;
      const distYd = 100.0;
      const dialMil = 5.0;
      // Commanded elevation: 5 mil × 3.6 in/mil/100yd = 18" up.
      // Aim at center (0, 0). Expected impact center = +18" from center
      // → norm = 18/12 = 1.5.
      const expectedNorm = 1.5;
      final impacts = <ScopeTrackingObservation>[
        for (final dy in [-0.005, 0.0, 0.005])
          ScopeTrackingObservation(impactX: 0, impactY: expectedNorm + dy),
      ];
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: dialMil,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: distYd,
        observations: impacts,
      );
      expect(result.derivedScale, closeTo(1.0, 0.005));
    });
  });

  group('Sight calibration — horizontal', () {
    test('windage axis works the same as elevation', () {
      const targetWidthIn = 24.0;
      const targetHeightIn = 24.0;
      const distYd = 100.0;
      const dialMil = 4.0; // dial 4 mil right
      const trueScale = 0.97;
      // Aim at left edge (-1, 0). Center commanded = -12 + 4 × 3.6 ×
      // trueScale = -12 + 13.968 = +1.968" → norm X = 0.164.
      const expectedNorm = (-12.0 + 4.0 * 3.6 * trueScale) / 12.0;
      final impacts = <ScopeTrackingObservation>[
        for (final dx in [-0.005, 0.0, 0.005])
          ScopeTrackingObservation(impactX: expectedNorm + dx, impactY: 0),
      ];
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.horizontal,
        aimPointX: -1.0,
        aimPointY: 0,
        advertisedDialMil: dialMil,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: distYd,
        observations: impacts,
      );
      expect(result.derivedScale, closeTo(trueScale, 0.005));
    });
  });

  group('Sight calibration — group RMS reporting', () {
    test('tighter group → smaller groupRmsIn', () {
      const targetWidthIn = 24.0;
      const targetHeightIn = 24.0;
      // Same expected centroid; different spread.
      const expectedNorm = 1.5;
      final tight = [
        for (final dy in [-0.005, 0.0, 0.005])
          ScopeTrackingObservation(impactX: 0, impactY: expectedNorm + dy),
      ];
      final loose = [
        for (final dy in [-0.05, 0.0, 0.05])
          ScopeTrackingObservation(impactX: 0, impactY: expectedNorm + dy),
      ];
      final tightR = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: 5,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: 100,
        observations: tight,
      );
      final looseR = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: 5,
        targetWidthIn: targetWidthIn,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: 100,
        observations: loose,
      );
      expect(tightR.groupRmsIn, lessThan(looseR.groupRmsIn));
    });
  });

  group('Sight calibration — degenerate inputs', () {
    test('empty observations returns scale 1.0', () {
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: 5,
        targetWidthIn: 24,
        targetHeightIn: 24,
        targetDistanceYd: 100,
        observations: const [],
      );
      expect(result.derivedScale, 1.0);
      expect(result.observations, isEmpty);
    });

    test('zero advertised dial returns scale 1.0', () {
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: 0,
        targetWidthIn: 24,
        targetHeightIn: 24,
        targetDistanceYd: 100,
        observations: const [
          ScopeTrackingObservation(impactX: 0, impactY: 0.5),
        ],
      );
      expect(result.derivedScale, 1.0);
    });
  });

  group('Sight calibration — JSON round trip', () {
    test('observations serialize and deserialize losslessly', () {
      const obs = [
        ScopeTrackingObservation(
            impactX: 0.05, impactY: 0.95, notes: 'shot 1'),
        ScopeTrackingObservation(impactX: -0.02, impactY: 0.92),
      ];
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: 0,
        advertisedDialMil: 5,
        targetWidthIn: 24,
        targetHeightIn: 24,
        targetDistanceYd: 100,
        observations: obs,
      );
      final json = result.observationJsonString();
      final restored = ScopeTrackingResult.observationsFromJson(json);
      expect(restored.length, 2);
      expect(restored[0].impactY, closeTo(0.95, 1e-9));
      expect(restored[0].notes, 'shot 1');
      expect(restored[1].notes, isNull);
    });
  });

  group('Sight calibration — measured mil reflects centroid offset', () {
    test('measured mil is consistent with the centroid-offset inches', () {
      const distYd = 100.0;
      const targetHeightIn = 24.0;
      const aimNorm = 0.0; // at center
      const centroidNorm = 0.5; // 25% up from center
      final observations = [
        for (final dy in [-0.01, 0, 0.01])
          ScopeTrackingObservation(impactX: 0, impactY: centroidNorm + dy),
      ];
      const expectedCentroidIn = (centroidNorm - aimNorm) * targetHeightIn / 2;
      final expectedMil =
          bu.inchesToMilAtYards(expectedCentroidIn, distYd);
      final result = _service.calibrate(
        axis: ScopeTrackingAxis.vertical,
        aimPointX: 0,
        aimPointY: aimNorm,
        advertisedDialMil: 5,
        targetWidthIn: 24,
        targetHeightIn: targetHeightIn,
        targetDistanceYd: distYd,
        observations: observations,
      );
      expect(result.measuredMil, closeTo(expectedMil, 0.01));
      expect(result.centroidOffsetIn,
          closeTo(expectedCentroidIn, 0.05));
    });
  });
}
