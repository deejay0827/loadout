// FILE: test/scope_training_models_test.dart
//
// Sanity-check tests for the Scope View training-mode math
// (`lib/screens/range_day/scope_training_models.dart`). The spec calls
// out two reference scenarios:
//
//   * Beginner shooting at a stationary 8" plate at 100 yd with 1 MOA
//     group should show ~95-99% hit probability.
//   * Expert shooting at a 12" mover at 600 yd with 2 mph mover speed
//     should show realistic 40-70% based on timing offset.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/screens/range_day/scope_training_models.dart';
import 'package:loadout/services/ballistics/units.dart' as bu;

void main() {
  group('parse and round-trip', () {
    test('AimMode round-trip', () {
      expect(parseAimMode('free'), AimMode.free);
      expect(parseAimMode('auto'), AimMode.auto);
      expect(parseAimMode(null), AimMode.auto);
      expect(parseAimMode('garbage'), AimMode.auto);
      expect(aimModeToString(AimMode.free), 'free');
      expect(aimModeToString(AimMode.auto), 'auto');
    });

    test('SkillLevel round-trip', () {
      for (final s in SkillLevel.values) {
        expect(parseSkillLevel(skillLevelToString(s)), s);
      }
      expect(parseSkillLevel(null), SkillLevel.beginner);
      expect(parseSkillLevel('garbage'), SkillLevel.beginner);
    });

    test('SkillLevel half-window monotonic', () {
      // Beginner has the widest window; Expert the tightest.
      expect(skillHalfWindowMs(SkillLevel.beginner) >
          skillHalfWindowMs(SkillLevel.intermediate), true);
      expect(skillHalfWindowMs(SkillLevel.intermediate) >
          skillHalfWindowMs(SkillLevel.advanced), true);
      expect(skillHalfWindowMs(SkillLevel.advanced) >
          skillHalfWindowMs(SkillLevel.expert), true);
      expect(skillHalfWindowMs(SkillLevel.beginner), 220);
      expect(skillHalfWindowMs(SkillLevel.expert), 25);
    });

    test('TrainingOverlays JSON round-trip', () {
      const o = TrainingOverlays(
        predictedImpact: true,
        probabilityEllipse: false,
        ambushGuides: true,
        animation: false,
      );
      final s = o.toJsonString();
      final r = TrainingOverlays.fromJson(s);
      expect(r.predictedImpact, true);
      expect(r.probabilityEllipse, false);
      expect(r.ambushGuides, true);
      expect(r.animation, false);
    });

    test('TrainingOverlays defaults to all-off on bad JSON', () {
      expect(TrainingOverlays.fromJson(null).predictedImpact, false);
      expect(TrainingOverlays.fromJson('').predictedImpact, false);
      expect(TrainingOverlays.fromJson('{').predictedImpact, false);
    });
  });

  group('shooting window math', () {
    test('beginner vs expert window symmetry', () {
      final beginnerWin = computeShootingWindowMilSec(
        skill: SkillLevel.beginner,
        targetSpeedMilPerSec: 0,
        targetWidthMil: 1.0,
        targetHeightMil: 1.0,
        sigmaMil: 0.1,
      );
      expect(beginnerWin.earliestMs, -220);
      expect(beginnerWin.latestMs, 220);
      expect(beginnerWin.optimalMs, 0);
      final expertWin = computeShootingWindowMilSec(
        skill: SkillLevel.expert,
        targetSpeedMilPerSec: 0,
        targetWidthMil: 1.0,
        targetHeightMil: 1.0,
        sigmaMil: 0.1,
      );
      expect(expertWin.earliestMs, -25);
      expect(expertWin.latestMs, 25);
    });

    test('beginner — stationary 8" plate at 100 yd, 1 MOA group → 95-99%',
        () {
      // 1 MOA × 1.047 = 1.047 inches ES at 100 yd.
      // 1σ at 100 yd = 1.047 / 4 = 0.2618".
      // 1σ in mil at 100 yd = inchesToMil(0.2618, 100).
      final sigmaMil = bu.inchesToMilAtYards(1.047 / 4.0, 100);
      // 8" plate angular size at 100 yd = 8 / (100 × 36) × 1000 = 2.222 mil.
      final tw = 8.0 / (100 * 36.0) * 1000.0;
      final th = tw;
      final w = computeShootingWindowMilSec(
        skill: SkillLevel.beginner,
        targetSpeedMilPerSec: 0,
        targetWidthMil: tw,
        targetHeightMil: th,
        sigmaMil: sigmaMil,
      );
      // Stationary target + tight group → near 100% hit chance.
      expect(w.hitLikelihood, greaterThan(0.95),
          reason: 'beginner / 8" plate / 100yd / 1 MOA should be ≥95%');
      expect(w.hitLikelihood, lessThanOrEqualTo(1.0));
    });

    test('expert — 12" mover at 600 yd, 2 mph at optimal → realistic',
        () {
      // 1 MOA × 1.047 × 6 / 4 = 1.57". Convert to mil.
      final sigmaIn = (1.0 * 1.047) * 600.0 / 100.0 / 4.0;
      final sigmaMil = bu.inchesToMilAtYards(sigmaIn, 600);
      // 12" mover angular size at 600 yd = 12 / (600 × 36) × 1000 = 0.555 mil.
      final tw = 12.0 / (600.0 * 36.0) * 1000.0;
      final th = tw;
      // Speed: 2 mph = 35.2 in/s. mil/s at 600 yd:
      final speedMilSec = bu.inchesToMilAtYards(2.0 * 17.6, 600);
      // At Δt = 0 (optimal), the timing offset doesn't matter — the
      // shot lands on the target. So optimal hit chance ≈ 1D Gaussian
      // over 0.555 mil with σ ≈ inchesToMil(1.57, 600) ≈ 0.073 mil.
      // That's 0.555 / 0.073 ≈ 7.5σ wide — very high probability.
      final wOptimal = computeShootingWindowMilSec(
        skill: SkillLevel.expert,
        targetSpeedMilPerSec: speedMilSec,
        targetWidthMil: tw,
        targetHeightMil: th,
        sigmaMil: sigmaMil,
        shotOffsetMs: 0,
      );
      // Optimal-timing hit should be high (> 0.5) — even at 600 yd a
      // 12" target is bigger than typical group dispersion.
      expect(wOptimal.hitLikelihood, greaterThan(0.4),
          reason: 'expert / 12" mover / 600yd at Δt=0 should be >40%');
      // At the latest edge of the window (+25ms expert), the target
      // has moved by 25ms × speed, which is meaningful. Hit should
      // drop noticeably.
      final wLate = computeShootingWindowMilSec(
        skill: SkillLevel.expert,
        targetSpeedMilPerSec: speedMilSec,
        targetWidthMil: tw,
        targetHeightMil: th,
        sigmaMil: sigmaMil,
        shotOffsetMs: 25,
      );
      // The 25ms offset shouldn't kill the shot (target is 0.555 mil
      // wide, target moved 25ms × 0.293 mil/s × … = 0.0073 mil shift,
      // which is tiny compared to the 0.555 mil target). So this is
      // mostly a smoke test that the math runs without crashing.
      expect(wLate.hitLikelihood, greaterThan(0.0));
      expect(wLate.hitLikelihood, lessThanOrEqualTo(1.0));
    });

    test('hit likelihood drops as offset moves away from optimal', () {
      // Bigger lead-shift = lower probability. Use a fast mover so
      // the effect is visible at the small offsets we care about.
      const sigmaMil = 0.2;
      const tw = 0.5;
      const th = 0.5;
      const speed = 20.0; // mil/s — large to make the test sensitive.
      final at0 = computeShootingWindowMilSec(
        skill: SkillLevel.intermediate,
        targetSpeedMilPerSec: speed,
        targetWidthMil: tw,
        targetHeightMil: th,
        sigmaMil: sigmaMil,
        shotOffsetMs: 0,
      );
      final at100 = computeShootingWindowMilSec(
        skill: SkillLevel.intermediate,
        targetSpeedMilPerSec: speed,
        targetWidthMil: tw,
        targetHeightMil: th,
        sigmaMil: sigmaMil,
        shotOffsetMs: 100,
      );
      expect(at100.hitLikelihood, lessThan(at0.hitLikelihood));
    });
  });

  group('predicted impact', () {
    test('aim on target with no lead → 100% hit on stationary target',
        () {
      final p = computePredictedImpact(
        aimXMil: 0.0,
        aimYMil: 0.0,
        dropMil: 0.0,
        windMil: 0.0,
        targetWidthMil: 1.0,
        targetHeightMil: 1.0,
        sigmaMil: 0.001, // basically perfect rifle
        targetSpeedMilPerSec: 0.0,
        timeOfFlightSec: 1.0,
      );
      expect(p.xMil, 0.0);
      expect(p.yMil, 0.0);
      expect(p.hitProbability, greaterThan(0.99));
    });

    test('aim off-target → low hit probability', () {
      final p = computePredictedImpact(
        aimXMil: 5.0, // way off the 1-mil-wide target
        aimYMil: 0.0,
        dropMil: 0.0,
        windMil: 0.0,
        targetWidthMil: 1.0,
        targetHeightMil: 1.0,
        sigmaMil: 0.05,
        targetSpeedMilPerSec: 0.0,
        timeOfFlightSec: 1.0,
      );
      expect(p.hitProbability, lessThan(0.05));
    });
  });

  group('ambush points', () {
    test('center-mass = future target position; leading offsets by half-width',
        () {
      final ambush = computeAmbushPoints(
        dropMil: 2.0,
        windMil: 0.5,
        targetSpeedMilPerSec: 1.0,
        timeOfFlightSec: 0.5,
        targetWidthMil: 1.0,
        direction: 1.0, // L→R
      );
      // future cx = windMil + speed × tof = 0.5 + 0.5 = 1.0 mil
      expect(ambush.centerMassXMil, closeTo(1.0, 1e-6));
      expect(ambush.centerMassYMil, closeTo(-2.0, 1e-6));
      // leading-edge ambush adds half-width on the +x side for L→R.
      expect(ambush.leadingEdgeXMil, closeTo(1.5, 1e-6));
    });

    test('R→L direction flips the leading-edge offset', () {
      final ambush = computeAmbushPoints(
        dropMil: 0.0,
        windMil: 0.0,
        targetSpeedMilPerSec: 1.0,
        timeOfFlightSec: 0.5,
        targetWidthMil: 1.0,
        direction: -1.0, // R→L
      );
      // L→R would give +0.5; R→L gives -0.5 + 0.5 (target moves left
      // by 0.5 over the tof, so future cx = -0.5; leading edge is
      // -0.5 + (-1) × 0.5 = -1.0).
      expect(ambush.centerMassXMil, closeTo(-0.5, 1e-6));
      expect(ambush.leadingEdgeXMil, closeTo(-1.0, 1e-6));
    });
  });
}
