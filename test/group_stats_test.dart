// FILE: test/group_stats_test.dart
//
// Unit tests for `lib/services/ballistics/group_stats.dart`. The function
// under test is pure — given a list of (x,y) shot impacts in inches and a
// session distance, it returns a `GroupStats` aggregate. The tests cover:
//
//   1. The "need more shots" sentinel — fewer than 2 shots returns null.
//   2. A 3-shot equilateral triangle with 1.5" sides — verifies extreme
//      spread, mean radius, and the centroid for a known geometry.
//   3. A 5-shot deterministic input — verifies horizontal / vertical SD
//      against hand-computed reference numbers.
//   4. Bullet-diameter inclusion — group size = ES + diameter.
//   5. distanceYd <= 0 → MOA fields are zero, not NaN.
//
// All assertions use `closeTo` with a 1e-6 tolerance on linear values
// and 1e-3 on MOA (rounding through the small-angle conversion only
// affects the last digit at typical distances).

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/services/ballistics/group_stats.dart';
import 'package:loadout/services/ballistics/units.dart' as bu;

void main() {
  group('computeGroupStats — sentinels', () {
    test('returns null for zero shots', () {
      final stats = computeGroupStats(points: const [], distanceYd: 100);
      expect(stats, isNull);
    });

    test('returns null for a single shot', () {
      final stats = computeGroupStats(
        points: const [Offset(0, 0)],
        distanceYd: 100,
      );
      expect(stats, isNull);
    });
  });

  group('computeGroupStats — 3-shot equilateral triangle', () {
    // Equilateral triangle with side length s = 1.5".
    // Vertices placed at:
    //   A = ( 0,            s * sqrt(3)/3            )    (top)
    //   B = (-s/2,         -s * sqrt(3)/6            )    (bottom-left)
    //   C = ( s/2,         -s * sqrt(3)/6            )    (bottom-right)
    // The centroid is exactly the origin by construction (coordinates
    // chosen so that A.y + B.y + C.y = 0 and B.x + C.x = 0).
    //
    // Reference values:
    //   ES        = s = 1.5"
    //   MR        = side / sqrt(3) = circumradius for equilateral
    //             = 1.5 / sqrt(3) ≈ 0.866025"
    //   sigma_x   = sqrt(((-0.75)^2 + 0.75^2 + 0^2) / 3) = sqrt(0.375)
    //             ≈ 0.612372"
    //   sigma_y   computed from the y components below.
    const s = 1.5;
    final h = s * math.sqrt(3) / 3; // top vertex y
    final low = -s * math.sqrt(3) / 6; // bottom y for B & C
    final pts = [
      Offset(0, h),
      Offset(-s / 2, low),
      Offset(s / 2, low),
    ];
    final stats = computeGroupStats(
      points: pts,
      distanceYd: 100,
    )!;

    test('extreme spread equals the side length (1.5")', () {
      expect(stats.extremeSpreadIn, closeTo(s, 1e-9));
    });

    test('mean radius equals the circumradius s/sqrt(3) ≈ 0.866"', () {
      expect(stats.meanRadiusIn, closeTo(s / math.sqrt(3), 1e-9));
    });

    test('centroid is the origin', () {
      expect(stats.centroidIn.dx, closeTo(0, 1e-9));
      expect(stats.centroidIn.dy, closeTo(0, 1e-9));
    });

    test('horizontal SD = sqrt(0.375) ≈ 0.6124"', () {
      // sigma_x^2 = mean( (-0.75)^2 + (0.75)^2 + 0 ) / 3 = 1.125/3 = 0.375
      expect(stats.horizontalSdIn, closeTo(math.sqrt(0.375), 1e-9));
    });

    test('shot count and ES MOA round-trip', () {
      expect(stats.shotCount, equals(3));
      // 1.5" at 100 yd → ~1.43 MOA.
      expect(
        stats.extremeSpreadMoa,
        closeTo(bu.inchesToMoaAtYards(s, 100), 1e-9),
      );
    });
  });

  group('computeGroupStats — 5-shot known positions', () {
    // Five shots at deterministic positions, chosen so the centroid is
    // exactly the origin and every reference number is an integer or
    // simple radical.
    //
    //   p1 = (-2, +2)    upper-left
    //   p2 = (+2, +2)    upper-right
    //   p3 = ( 0,  0)    center
    //   p4 = (-2, -2)    lower-left
    //   p5 = (+2, -2)    lower-right
    //
    // Reference values:
    //   centroid    = (0, 0)
    //   ES          = ||(2,2) - (-2,-2)|| = sqrt(32) = 4*sqrt(2) ≈ 5.6568542
    //               (and equally for ||(2,-2) - (-2,2)||)
    //   |p_i - c|   = [ sqrt(8), sqrt(8), 0, sqrt(8), sqrt(8) ]
    //   MR          = (4 * sqrt(8) + 0) / 5 = 4*2*sqrt(2)/5
    //               = 8*sqrt(2)/5 ≈ 2.2627417
    //   sigma_x^2   = (4 + 4 + 0 + 4 + 4) / 5 = 16/5 = 3.2
    //   sigma_x     = sqrt(3.2) ≈ 1.7888544
    //   sigma_y     = same ≈ 1.7888544 (by symmetry)
    final pts = const [
      Offset(-2, 2),
      Offset(2, 2),
      Offset(0, 0),
      Offset(-2, -2),
      Offset(2, -2),
    ];

    test('all stats match hand-computed reference at 100 yd', () {
      final stats = computeGroupStats(
        points: pts,
        distanceYd: 100,
        bulletDiameterIn: 0.264,
      )!;

      expect(stats.shotCount, equals(5));
      expect(stats.centroidIn.dx, closeTo(0, 1e-9));
      expect(stats.centroidIn.dy, closeTo(0, 1e-9));
      expect(stats.extremeSpreadIn, closeTo(4 * math.sqrt(2), 1e-9));
      expect(stats.meanRadiusIn, closeTo(8 * math.sqrt(2) / 5, 1e-9));
      expect(stats.horizontalSdIn, closeTo(math.sqrt(3.2), 1e-9));
      expect(stats.verticalSdIn, closeTo(math.sqrt(3.2), 1e-9));
      // Group size includes one bullet diameter.
      expect(
        stats.groupSizeIn,
        closeTo(4 * math.sqrt(2) + 0.264, 1e-9),
      );
      // MOA fields agree with the canonical conversion.
      expect(
        stats.extremeSpreadMoa,
        closeTo(bu.inchesToMoaAtYards(4 * math.sqrt(2), 100), 1e-6),
      );
    });

    test('non-zero centroid is reported correctly', () {
      // Shift every point by (+1, -0.5) — centroid should follow.
      final shifted = pts
          .map((p) => Offset(p.dx + 1.0, p.dy - 0.5))
          .toList();
      final stats = computeGroupStats(
        points: shifted,
        distanceYd: 100,
      )!;
      expect(stats.centroidIn.dx, closeTo(1.0, 1e-9));
      expect(stats.centroidIn.dy, closeTo(-0.5, 1e-9));
      // ES is invariant under translation.
      expect(stats.extremeSpreadIn, closeTo(4 * math.sqrt(2), 1e-9));
    });
  });

  group('computeGroupStats — distance edge cases', () {
    test('distanceYd <= 0 yields zero MOA, not NaN', () {
      final stats = computeGroupStats(
        points: const [Offset(0, 0), Offset(1, 0)],
        distanceYd: 0,
      )!;
      expect(stats.extremeSpreadIn, closeTo(1.0, 1e-9));
      expect(stats.extremeSpreadMoa, equals(0.0));
      expect(stats.meanRadiusMoa, equals(0.0));
      expect(stats.groupSizeMoa, equals(0.0));
    });

    test('group size at 100yd is ES + bullet diameter, in inches and MOA', () {
      final stats = computeGroupStats(
        points: const [Offset(0, 0), Offset(2, 0)],
        distanceYd: 100,
        bulletDiameterIn: 0.308,
      )!;
      expect(stats.extremeSpreadIn, closeTo(2.0, 1e-9));
      expect(stats.groupSizeIn, closeTo(2.308, 1e-9));
      expect(
        stats.groupSizeMoa,
        closeTo(bu.inchesToMoaAtYards(2.308, 100), 1e-9),
      );
    });
  });
}
