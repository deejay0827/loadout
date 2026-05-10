// FILE: lib/services/scope_tracking_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Scope Tracking Test — Drop-Per-Click (DPC) sight calibration (formerly
// known internally as "Sight Calibration"). Derives the firearm's true
// sight scale factor (vertical or horizontal) from observed shot impacts
// on a known-distance, known-dial test target.
//
// Many scopes don't track exactly to their advertised increments. A turret
// labeled "0.1 mil per click" might actually move 0.097 mil per click.
// Across a 50-click dial that's a 1.5-click error — at 1000 yards that's
// over a foot of impact-point error. industry standard / Long Range Shooting (and
// Applied Ballistics) have a standard procedure to detect and correct
// this, called the "tall target test":
//
//   1. Hang a target with a vertical (or horizontal) reference line at a
//      known distance — typically 100 yards.
//   2. Aim at the bottom of the line, fire a fouling shot, then dial up a
//      known elevation amount (e.g. 10 mil up).
//   3. Fire 3-5 shots without changing aim. Their centroid is where the
//      scope ACTUALLY moved the bullet's point of impact.
//   4. Measure the centroid's vertical offset from the aim point.
//   5. Compute the *measured* mil-per-click = measured offset / commanded
//      dial in mil. The scale factor is measured / advertised.
//
// This service implements step 5 — given the impacts (in normalized
// target coords matching the rest of the Range Day workspace), the
// distance, and the commanded dial amount, derive the scale factor.
//
// Public API:
//
//   * `class ScopeTrackingObservation` — one impact entry. Same shape
//     as `ShotImpactRow.impactX/impactY` (normalized to [-1, 1] across
//     the target). Calibration uses these directly.
//
//   * `class ScopeTrackingResult` — derived ratio plus diagnostics
//     (centroid offset in mil, residuals from each impact, group RMS).
//
//   * `class ScopeTrackingService` — stateless. One method,
//     `calibrate(...)`.
//
// ============================================================================
// THE MATH
// ============================================================================
// Convert each normalized impact coordinate to inches at the target:
//
//     impactInchesY = impactY * targetHeightIn / 2
//
// Compute the centroid of the impacts (mean of all observation y-values).
// The centroid is the unbiased estimator of the scope's actual "where it
// puts the impact" given the dial setting. We use the centroid rather
// than any single shot because individual impacts carry the rifle's
// intrinsic group dispersion (~0.5 MOA at 100 yd ≈ 0.5") plus shooter
// noise; the centroid drains out that noise as the sample size grows.
//
// Convert the centroid offset to angular mils at the target distance:
//
//     measuredMil = atan(centroidInches / (distanceYd × 36)) × 1000
//
// (rangeInches = yards × 36; tan(θ) ≈ θ in mil for small angles.)
//
// The advertised dial amount is what the user told us they dialed. The
// actual mil-per-click is measuredMil / clicks if we know the click count;
// equivalently the **scale factor** is:
//
//     scale = measuredMil / advertisedMil
//
// Where:
//   * scale = 1.0 → scope tracks perfectly.
//   * scale < 1.0 → scope undertracks (dialing up 10 mil moves impact
//     less than 10 mil; the user needs to dial MORE to hit the right
//     elevation).
//   * scale > 1.0 → scope overtracks (rare, but seen on cheap scopes).
//
// For the firearm row's `sightScaleVertical` / `sightScaleHorizontal`
// fields, we store `scale` as-is. The solver multiplies its commanded
// elevation by this factor when reporting the dial amount, so a user
// with a 0.97 scope sees holdover values 3% smaller — matching what
// they'll actually need to dial on the turret.
//
// ============================================================================
// HOW MANY SHOTS IS ENOUGH?
// ============================================================================
// The standard error of the centroid is σ_group / √n. With σ_group ≈ 0.3"
// at 100 yd and N=3 shots: SE = 0.17". At a 10 mil dial and 100 yd, that's
// a 0.005 scale uncertainty (0.5 % of the measured ratio). Five shots cuts
// it to 0.13" / 0.004 scale uncertainty — well below the variability of
// the scope's clicks themselves.
//
// We surface RMS group spread in the result so the UI can show the user
// "your group at the dial point was 0.4 MOA" — useful context for whether
// the calibration is good (tight group) or noisy (1.5 MOA, calibration
// suspect).
//
// ============================================================================
// REFERENCES
// ============================================================================
//   * industry-standard, "Modern Advancements in Long Range Shooting Vol 1",
//     ch. 1 (Tall Target Test). The methodology.
//   * Frank Galli, "Tall target test" — Sniper's Hide tutorial covering
//     the operator-side procedure.

import 'dart:convert';
import 'dart:math' as math;

import 'ballistics/units.dart' as bu;

/// One impact observation in normalized target coords. Same coordinate
/// system as `ShotImpactRow.impactX/impactY`: [-1, 1] across each axis,
/// (0, 0) = dead center, (1, 1) = top-right.
class ScopeTrackingObservation {
  const ScopeTrackingObservation({
    required this.impactX,
    required this.impactY,
    this.notes,
  });

  final double impactX;
  final double impactY;
  final String? notes;

  Map<String, dynamic> toJson() => {
        'impactX': impactX,
        'impactY': impactY,
        if (notes != null) 'notes': notes,
      };

  static ScopeTrackingObservation fromJson(Map<String, dynamic> j) =>
      ScopeTrackingObservation(
        impactX: (j['impactX'] as num).toDouble(),
        impactY: (j['impactY'] as num).toDouble(),
        notes: j['notes'] as String?,
      );
}

/// Which axis the calibration is measuring. Vertical = elevation
/// turret, horizontal = windage turret. Each can have a different
/// scale factor (scopes occasionally track different on the two
/// axes after a hard knock).
enum ScopeTrackingAxis {
  vertical,
  horizontal;

  String get dbValue {
    switch (this) {
      case ScopeTrackingAxis.vertical:
        return 'vertical';
      case ScopeTrackingAxis.horizontal:
        return 'horizontal';
    }
  }

  static ScopeTrackingAxis fromDbValue(String s) {
    switch (s) {
      case 'horizontal':
        return ScopeTrackingAxis.horizontal;
      case 'vertical':
      default:
        return ScopeTrackingAxis.vertical;
    }
  }
}

/// Output of [ScopeTrackingService.calibrate].
class ScopeTrackingResult {
  const ScopeTrackingResult({
    required this.axis,
    required this.advertisedMil,
    required this.measuredMil,
    required this.derivedScale,
    required this.observations,
    required this.centroidOffsetIn,
    required this.groupRmsIn,
  });

  final ScopeTrackingAxis axis;

  /// What the user said they dialed, in mil. Treated as the truth — if
  /// they dialed 10 clicks of "0.1 mil per click" they tell the wizard
  /// they dialed 1.0 mil. The wizard doesn't try to back-derive the
  /// advertised click size from the click count.
  final double advertisedMil;

  /// What the scope actually moved the impact, in mil at the target
  /// distance.
  final double measuredMil;

  /// `measuredMil / advertisedMil`. This is the value to write to
  /// `UserFirearms.sightScaleVertical` (or `sightScaleHorizontal`) so
  /// the solver picks it up. 1.0 = no correction.
  final double derivedScale;

  /// The observations the calibration was performed against.
  final List<ScopeTrackingObservation> observations;

  /// Centroid offset from the aim point on the chosen axis, in inches at
  /// the target. For UI display ("your impacts averaged 9.7" above the
  /// aim point").
  final double centroidOffsetIn;

  /// RMS of the impacts about the centroid on the chosen axis, in
  /// inches. A measure of the group's tightness on the calibration
  /// axis. Surfaced so users can see whether the calibration was
  /// taken with a tight enough group to trust the result.
  final double groupRmsIn;

  String observationJsonString() =>
      jsonEncode(observations.map((o) => o.toJson()).toList());

  static List<ScopeTrackingObservation> observationsFromJson(String s) {
    final list = jsonDecode(s) as List;
    return list
        .map((e) =>
            ScopeTrackingObservation.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

class ScopeTrackingService {
  const ScopeTrackingService();

  /// Compute the scale factor.
  ///
  /// `aimPointX` / `aimPointY` are in normalized target coords (same
  /// scale as [ScopeTrackingObservation.impactX/impactY]). For a
  /// classic vertical tall-target test the user holds at the bottom
  /// edge of the reference line, so `aimPointX = 0`, `aimPointY = -1`
  /// (-1 = bottom edge). The wizard captures the aim point from the
  /// existing `RangeDaySessions.aimPointX/Y` columns when available;
  /// when not, it defaults to (0, 0) and the user is asked to set it.
  ///
  /// `advertisedDialMil` is what the user tells the wizard they dialed.
  /// Most users dial "10 mil up" or "5 MOA right" — translate MOA to
  /// mil before calling (the existing units helpers do this).
  ScopeTrackingResult calibrate({
    required ScopeTrackingAxis axis,
    required double aimPointX, // [-1..1]
    required double aimPointY, // [-1..1]
    required double advertisedDialMil,
    required double targetWidthIn,
    required double targetHeightIn,
    required double targetDistanceYd,
    required List<ScopeTrackingObservation> observations,
  }) {
    if (observations.isEmpty || advertisedDialMil == 0) {
      return ScopeTrackingResult(
        axis: axis,
        advertisedMil: advertisedDialMil,
        measuredMil: 0,
        derivedScale: 1.0,
        observations: const [],
        centroidOffsetIn: 0,
        groupRmsIn: 0,
      );
    }

    // Convert each impact to inches at the target on the chosen axis.
    final inchesPerNorm = axis == ScopeTrackingAxis.vertical
        ? targetHeightIn / 2.0
        : targetWidthIn / 2.0;
    final aimNormOnAxis =
        axis == ScopeTrackingAxis.vertical ? aimPointY : aimPointX;
    final aimInchesOnAxis = aimNormOnAxis * inchesPerNorm;

    // Centroid of the impacts on the chosen axis, in inches at the target.
    final impactsInchesOnAxis = observations.map((o) {
      final norm = axis == ScopeTrackingAxis.vertical ? o.impactY : o.impactX;
      return norm * inchesPerNorm;
    }).toList();
    final mean = impactsInchesOnAxis.reduce((a, b) => a + b) /
        impactsInchesOnAxis.length;

    // Centroid offset = (centroid - aim point) on the chosen axis.
    // Sign convention: positive = scope moved impact AWAY from aim in
    // the same direction the user said they dialed. We expect
    // advertisedDialMil to be a signed quantity (positive = up / right).
    final centroidOffsetIn = mean - aimInchesOnAxis;

    // Convert the offset to mil at the target distance.
    final measuredMil = bu.inchesToMilAtYards(centroidOffsetIn, targetDistanceYd);

    // Derived scale: measured / advertised. We let advertisedDialMil
    // carry sign and treat the ratio so a user who dials "10 mil up"
    // and observes "9.7 mil up" gets +0.97. Negative dials work too —
    // the math is symmetric.
    //
    // Edge case: if measuredMil and advertisedDialMil have OPPOSITE
    // signs (the impacts went the wrong way relative to what the dial
    // commanded), the ratio is negative. This is real-world possible
    // (a scope mounted backwards, a swapped click direction); we
    // surface the negative scale so the UI can warn the user rather
    // than silently writing -0.97 to the firearm row. Callers can
    // clamp / abs() / reject as they see fit.
    final derivedScale = measuredMil / advertisedDialMil;

    // RMS of the impact's distance from the centroid on the chosen
    // axis, in inches. Smaller = tighter group = more trustworthy
    // calibration.
    var sumSq = 0.0;
    for (final v in impactsInchesOnAxis) {
      final d = v - mean;
      sumSq += d * d;
    }
    final groupRmsIn =
        math.sqrt(sumSq / impactsInchesOnAxis.length);

    return ScopeTrackingResult(
      axis: axis,
      advertisedMil: advertisedDialMil,
      measuredMil: measuredMil,
      derivedScale: derivedScale,
      observations: List.unmodifiable(observations),
      centroidOffsetIn: centroidOffsetIn,
      groupRmsIn: groupRmsIn,
    );
  }
}
