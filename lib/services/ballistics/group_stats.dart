// FILE: lib/services/ballistics/group_stats.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Pure-Dart helper that turns a list of recorded shot impacts into the
// statistics a precision shooter actually wants to see after pulling a
// group: extreme spread, mean radius, group MOA, horizontal / vertical
// standard deviation, and the centroid offset (the load-bias the user can
// dial out at the scope).
//
// The functions here are *intentionally* free of Flutter / Drift imports
// so they can be unit-tested in headless Dart and reused on watchOS / Wear
// OS companion code if that becomes useful. The Range Day screen wraps the
// raw `ShotImpactRow` rows into `Offset` (inches relative to target
// center) and hands them in.
//
// ============================================================================
// FORMULAS
// ============================================================================
//
//   centroid       = (mean(x_i), mean(y_i))
//   ES (extreme    = max_{i,j} ||p_i - p_j||  (longest pairwise distance,
//      spread)                                 center-to-center)
//   group size     = ES + bullet_diameter      (outside-edge span — what
//                                                a caliper measures when
//                                                the bullets touch the
//                                                paper at the right edge)
//   mean radius    = mean_i ||p_i - centroid||
//   sigma_x        = sqrt(mean((x_i - cx)^2))  population SD, NOT sample
//   sigma_y        = sqrt(mean((y_i - cy)^2))  SD — for n in [2, 30] the
//                                                difference is tiny and
//                                                the population form has
//                                                a useful "n=1 → 0" limit
//
// MOA conversion uses [inchesToMoaAtYards] so 0 yd correctly returns 0
// instead of throwing a divide-by-zero — the caller can render "—" when
// the session distance is unset.
//
// ============================================================================
// WHY POPULATION SD AND NOT SAMPLE SD
// ============================================================================
// The classical sample-SD estimator divides by (n-1), which corrects bias
// when the sample is drawn from an infinite hypothetical population. Group
// statistics in shooting are descriptive: we are summarizing the shots we
// actually pulled, not estimating the shooter's true population variance.
// For descriptive use the population form (divide by n) is the right
// answer and matches what most ballistics tools (LabRadar, On Target TDS,
// Modern Marksmanship) report. The difference is bounded by `sqrt(n/(n-1))`
// which is < 4% for n >= 6 and converges quickly.
//
// We can revisit if real users want sample SD; the call site is two lines.

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'units.dart' as units;

/// Aggregate group-level metrics computed from a set of recorded shots.
///
/// All length values are in INCHES at the target. Angular values are in
/// MOA; convert to MIL via [units.inchesToMilAtYards] at the call site if
/// needed. Returns `null` from [computeGroupStats] when there are fewer
/// than 2 shots.
class GroupStats {
  const GroupStats({
    required this.shotCount,
    required this.extremeSpreadIn,
    required this.extremeSpreadMoa,
    required this.meanRadiusIn,
    required this.meanRadiusMoa,
    required this.groupSizeIn,
    required this.groupSizeMoa,
    required this.horizontalSdIn,
    required this.verticalSdIn,
    required this.centroidIn,
  });

  /// Number of shots that contributed to the statistics.
  final int shotCount;

  /// Longest center-to-center distance between any two shots (inches).
  final double extremeSpreadIn;

  /// [extremeSpreadIn] expressed as MOA at the session distance. 0 if
  /// the session distance was 0/unset.
  final double extremeSpreadMoa;

  /// Mean radius — average distance from each shot to the group centroid.
  final double meanRadiusIn;

  /// Mean radius converted to MOA at the session distance.
  final double meanRadiusMoa;

  /// "Outside edge" group size — extreme spread plus one bullet diameter.
  /// This is the number a caliper reads off the paper when measuring
  /// edge-to-edge.
  final double groupSizeIn;

  /// [groupSizeIn] in MOA at the session distance.
  final double groupSizeMoa;

  /// Population standard deviation of horizontal impacts (inches).
  final double horizontalSdIn;

  /// Population standard deviation of vertical impacts (inches).
  final double verticalSdIn;

  /// Group centroid expressed in inches relative to target center. The
  /// dx component is positive-right, dy is positive-up to match the
  /// shooter's mental model. The reverse of this vector is the scope
  /// adjustment that would re-center the group.
  final Offset centroidIn;
}

/// Compute group statistics from a list of shot impacts in inches
/// relative to the target's center.
///
/// `points` must be in inches with positive x = right of center and
/// positive y = above center (this matches the convention used in
/// `lib/screens/range_day/range_day_detail_screen.dart` after converting
/// normalized impacts to inches via the target's width/height).
///
/// `bulletDiameterIn` is added to the extreme spread to produce
/// [GroupStats.groupSizeIn] (the outside-edge measurement a caliper
/// would give). Defaults to 0 — pass the active load's bullet diameter
/// when computing the displayed group size.
///
/// `distanceYd` is used to convert linear group dimensions to MOA. Pass
/// 0 (or any non-positive value) when the session distance isn't known
/// yet — the MOA fields will be 0 in that case rather than NaN.
///
/// Returns `null` when fewer than 2 points are supplied — group stats
/// only make sense for 2+ shots, and the UI should render a "Need ≥2
/// shots" placeholder instead.
GroupStats? computeGroupStats({
  required List<Offset> points,
  required double distanceYd,
  double bulletDiameterIn = 0.0,
}) {
  if (points.length < 2) return null;

  // Centroid — arithmetic mean of x and y components.
  double sumX = 0;
  double sumY = 0;
  for (final p in points) {
    sumX += p.dx;
    sumY += p.dy;
  }
  final cx = sumX / points.length;
  final cy = sumY / points.length;
  final centroid = Offset(cx, cy);

  // Extreme spread — max pairwise center-to-center distance. O(n^2),
  // fine for the 5–20 shots a real range-day session ever has.
  double maxD = 0.0;
  for (var i = 0; i < points.length; i++) {
    for (var j = i + 1; j < points.length; j++) {
      final dx = points[i].dx - points[j].dx;
      final dy = points[i].dy - points[j].dy;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > maxD) maxD = d;
    }
  }

  // Mean radius — mean distance from each point to the centroid.
  double sumR = 0.0;
  // Population variance accumulators — divide by N at the end.
  double sumDx2 = 0.0;
  double sumDy2 = 0.0;
  for (final p in points) {
    final dx = p.dx - cx;
    final dy = p.dy - cy;
    sumR += math.sqrt(dx * dx + dy * dy);
    sumDx2 += dx * dx;
    sumDy2 += dy * dy;
  }
  final meanRadius = sumR / points.length;
  final sigmaX = math.sqrt(sumDx2 / points.length);
  final sigmaY = math.sqrt(sumDy2 / points.length);

  final groupSizeIn = maxD + bulletDiameterIn;
  final esMoa = distanceYd <= 0
      ? 0.0
      : units.inchesToMoaAtYards(maxD, distanceYd);
  final mrMoa = distanceYd <= 0
      ? 0.0
      : units.inchesToMoaAtYards(meanRadius, distanceYd);
  final groupSizeMoa = distanceYd <= 0
      ? 0.0
      : units.inchesToMoaAtYards(groupSizeIn, distanceYd);

  return GroupStats(
    shotCount: points.length,
    extremeSpreadIn: maxD,
    extremeSpreadMoa: esMoa,
    meanRadiusIn: meanRadius,
    meanRadiusMoa: mrMoa,
    groupSizeIn: groupSizeIn,
    groupSizeMoa: groupSizeMoa,
    horizontalSdIn: sigmaX,
    verticalSdIn: sigmaY,
    centroidIn: centroid,
  );
}
