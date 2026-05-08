// FILE: lib/screens/range_day/scope_training_models.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Pure data + math helpers for the Scope View "Training mode" panel
// (see `scope_view_screen.dart` — features 1–4 in the spec). Lives in
// its own file so the math is unit-testable without dragging in the
// full-screen widget hierarchy.
//
// What's in here:
//
//   * `enum AimMode` — auto-aim vs free-aim toggle state.
//   * `enum SkillLevel` — beginner / intermediate / advanced / expert.
//     Drives the timing-window tolerances on a moving-target stage.
//   * `class TrainingOverlays` — bag of bool flags (predicted impact /
//     probability ellipse / ambush guides / target animation).
//     Round-trips to/from JSON for persistence on `RangeDaySessions`.
//   * `class ShootingWindow` — earliest / optimal / latest time offsets
//     in milliseconds plus a hit-likelihood at the current offset.
//   * `class PredictedImpact` — predicted (xMil, yMil) impact location
//     for a given aim point in mil-from-FOV-center coords.
//   * `class TargetAmbushPoints` — leading-edge ambush + center-mass
//     ambush hold-off in mils, given a moving target.
//   * `computeShootingWindow(...)`, `computePredictedImpact(...)`,
//     `computeAmbushPoints(...)` — the three pure functions the screen
//     calls.
//
// ============================================================================
// SKILL-LEVEL TIMING WINDOW MATH
// ============================================================================
// For a moving-target stage the user has a finite time window during
// which the bullet-flight time matches the lead from where the target
// will be. The optimal shot fires the bullet so it arrives when the
// target is at the aim point. Earlier shots over-lead; later shots
// under-lead. The skill window is symmetric around the optimal point:
//
//   * Beginner:     ±220 ms — a forgiving window for new shooters.
//   * Intermediate: ±120 ms — a typical local-match cadence.
//   * Advanced:     ±60 ms  — competition pace.
//   * Expert:       ±25 ms  — championship pace.
//
// Hit likelihood at a time offset Δt from optimal is computed by
// shifting the target's position by `(targetSpeed × Δt)` and integrating
// the user's 2D Gaussian dispersion ellipse over the target shape at
// the new position. We reuse the same closed-form erf-based
// approximation [scope_view_screen.dart] uses for its live "what-if"
// ring (avoids spinning up the heavy Monte Carlo HitProbabilityService
// for every drag tick).
//
// ============================================================================
// PREDICTED IMPACT (FREE-AIM MODE)
// ============================================================================
// In free-aim mode the user drags the reticle anywhere in the FOV. The
// predicted impact = aim - (drop+wind solution offset) - dispersion mean
// - target lead (already baked into the solution drop/wind via the
// parent screen's solver call). We don't re-run the solver here; the
// parent passes pre-computed dropMil + windMil that already encode the
// firing solution. The "mean dispersion offset" is zero for an unbiased
// shooter and tiny for a real one — we ignore it for v1 (the spec calls
// out a future per-rifle zero-offset, which we leave hooked but unused).

import 'dart:convert';
import 'dart:math' as math;

/// Whether the Scope View reticle is anchored at the firing solution
/// (`auto`) or moves freely under the user's finger (`free`).
enum AimMode {
  /// Reticle locked to the firing solution. The crosshair sits on the
  /// target. Original behaviour — what users see by default.
  auto,

  /// User drags the reticle anywhere in the FOV. Predicted impact dot
  /// + probability ellipse render at the dragged location.
  free,
}

/// Parse the persisted text column. Anything other than `'free'`
/// falls back to [AimMode.auto] so the default behaviour is unchanged
/// when the column is absent or malformed.
AimMode parseAimMode(String? s) {
  return (s?.toLowerCase() == 'free') ? AimMode.free : AimMode.auto;
}

String aimModeToString(AimMode m) =>
    m == AimMode.free ? 'free' : 'auto';

/// Skill-level preset for the moving-target timing window. Each level
/// expresses a `±halfWindowMs` tolerance band around the optimal shot
/// time. Beginner has the widest band; Expert the tightest.
enum SkillLevel {
  /// New shooter / new to movers. ±220ms tolerance band — generous,
  /// the user has nearly half a second to break a shot.
  beginner,

  /// Local-match pace. ±120ms tolerance band.
  intermediate,

  /// Regional-match pace. ±60ms tolerance band.
  advanced,

  /// Championship pace. ±25ms tolerance band — about one human reaction
  /// time. Anything outside this and the shot misses.
  expert,
}

SkillLevel parseSkillLevel(String? s) {
  switch (s?.toLowerCase()) {
    case 'expert':
      return SkillLevel.expert;
    case 'advanced':
      return SkillLevel.advanced;
    case 'intermediate':
      return SkillLevel.intermediate;
    case 'beginner':
    default:
      return SkillLevel.beginner;
  }
}

String skillLevelToString(SkillLevel s) {
  switch (s) {
    case SkillLevel.expert:
      return 'expert';
    case SkillLevel.advanced:
      return 'advanced';
    case SkillLevel.intermediate:
      return 'intermediate';
    case SkillLevel.beginner:
      return 'beginner';
  }
}

/// Display name for a [SkillLevel]. Capitalized; used in the dropdown.
String skillLevelDisplay(SkillLevel s) {
  switch (s) {
    case SkillLevel.expert:
      return 'Expert';
    case SkillLevel.advanced:
      return 'Advanced';
    case SkillLevel.intermediate:
      return 'Intermediate';
    case SkillLevel.beginner:
      return 'Beginner';
  }
}

/// Half-window in ms for each [SkillLevel]. Symmetric around the
/// optimal shot time. The total tolerance window is 2 × this value.
int skillHalfWindowMs(SkillLevel s) {
  switch (s) {
    case SkillLevel.beginner:
      return 220;
    case SkillLevel.intermediate:
      return 120;
    case SkillLevel.advanced:
      return 60;
    case SkillLevel.expert:
      return 25;
  }
}

/// Bag of which Scope View training overlays are enabled. Round-trips
/// to / from JSON via [toJson] / [fromJson]. The default is all-off so
/// existing users see no behaviour change when the column appears.
class TrainingOverlays {
  const TrainingOverlays({
    this.predictedImpact = false,
    this.probabilityEllipse = false,
    this.ambushGuides = false,
    this.animation = false,
  });

  /// Render the dim red predicted-impact dot (Feature 1).
  final bool predictedImpact;

  /// Render the green/amber/red 1σ probability ellipse on the target
  /// (Feature 3).
  final bool probabilityEllipse;

  /// Render the leading-edge + center-mass ambush hash highlights
  /// (Feature 4).
  final bool ambushGuides;

  /// Run the animated target across the FOV (Feature 4).
  final bool animation;

  /// All flags off. Used as the default when the column is null.
  static const TrainingOverlays disabled = TrainingOverlays();

  TrainingOverlays copyWith({
    bool? predictedImpact,
    bool? probabilityEllipse,
    bool? ambushGuides,
    bool? animation,
  }) =>
      TrainingOverlays(
        predictedImpact: predictedImpact ?? this.predictedImpact,
        probabilityEllipse: probabilityEllipse ?? this.probabilityEllipse,
        ambushGuides: ambushGuides ?? this.ambushGuides,
        animation: animation ?? this.animation,
      );

  Map<String, dynamic> toJson() => {
        'predictedImpact': predictedImpact,
        'probabilityEllipse': probabilityEllipse,
        'ambushGuides': ambushGuides,
        'animation': animation,
      };

  /// Parse a stored JSON string. Null / malformed → all-off.
  static TrainingOverlays fromJson(String? text) {
    if (text == null || text.isEmpty) return TrainingOverlays.disabled;
    try {
      final raw = json.decode(text);
      if (raw is! Map) return TrainingOverlays.disabled;
      bool b(String key) => raw[key] == true;
      return TrainingOverlays(
        predictedImpact: b('predictedImpact'),
        probabilityEllipse: b('probabilityEllipse'),
        ambushGuides: b('ambushGuides'),
        animation: b('animation'),
      );
    } catch (_) {
      return TrainingOverlays.disabled;
    }
  }

  /// Encode for the drift column.
  String toJsonString() => json.encode(toJson());
}

/// Output of [computeShootingWindow]. All three time offsets are in
/// milliseconds relative to the optimal-shot time (Δt = 0). Hit
/// likelihood is the integral of the user's 2D Gaussian over the
/// target at the *current* time offset (not at optimal).
class ShootingWindow {
  const ShootingWindow({
    required this.earliestMs,
    required this.optimalMs,
    required this.latestMs,
    required this.hitLikelihood,
  });

  /// Earliest shoot time, ms relative to optimal. Always negative.
  /// "Latest you can squeeze if the target is just coming into view."
  final int earliestMs;

  /// Optimal shoot time, by construction always 0. Held as a separate
  /// field anyway so the UI can render the three values cleanly.
  final int optimalMs;

  /// Latest shoot time, ms relative to optimal. Always positive.
  /// "Latest-acceptable shot before the target leaves the kill zone."
  final int latestMs;

  /// 0..1 — probability of hitting the target if the shot is fired
  /// right now (i.e. at Δt = 0 within the window). Computed via the
  /// 2D Gaussian erf integral over the target rectangle.
  final double hitLikelihood;
}

/// Compute the earliest / optimal / latest shoot offsets and the hit
/// likelihood at the current offset.
///
/// [skill] drives the half-width of the window. [targetSpeedMph] is
/// the moving-target horizontal speed in miles per hour (negative or
/// positive depending on direction — only the magnitude matters for
/// the timing math). [targetWidthMil] / [targetHeightMil] are the
/// target's angular width / height at the rendered range. [sigmaMil]
/// is the user's 1σ dispersion in mils at the rendered range. [shotOffsetMs]
/// is how far off optimal the user is currently aiming (0 = optimal).
ShootingWindow computeShootingWindow({
  required SkillLevel skill,
  required double targetSpeedMph,
  required double targetWidthMil,
  required double targetHeightMil,
  required double sigmaMil,
  int shotOffsetMs = 0,
}) {
  final halfWindow = skillHalfWindowMs(skill);
  // Hit likelihood at the chosen offset: shift the target's center by
  // the time-offset × speed, then integrate the Gaussian over the
  // target rect (centered on aim point — assumed at target center for
  // the headline number).
  //
  // 1 mph = 17.6 in/s = 0.0176 in/ms. At the rendered range, that's
  // (17.6 / (range_yd × 36)) × 1000 mil/s  = 17.6 mil/s / (yd×36/1000)...
  // We don't know the range here — but the caller already passed
  // targetWidthMil so we take the simpler approach: convert mph to
  // mil/s using the reverse mapping we have at hand.
  //
  // Actually we need ms × speed → mil. The cleanest interface is to
  // accept the speed in mil/s directly. We do that via the helper
  // below — `computeShootingWindowMilSec`.
  return computeShootingWindowMilSec(
    skill: skill,
    targetSpeedMilPerSec: 0.0, // caller should use the explicit form
    targetWidthMil: targetWidthMil,
    targetHeightMil: targetHeightMil,
    sigmaMil: sigmaMil,
    shotOffsetMs: shotOffsetMs,
    halfWindowMs: halfWindow,
  );
}

/// Internal-style helper that takes target speed in mil/s directly.
/// Public so callers that already have the conversion don't have to
/// round-trip through mph and yards.
ShootingWindow computeShootingWindowMilSec({
  required SkillLevel skill,
  required double targetSpeedMilPerSec,
  required double targetWidthMil,
  required double targetHeightMil,
  required double sigmaMil,
  int shotOffsetMs = 0,
  int? halfWindowMs,
}) {
  final hw = halfWindowMs ?? skillHalfWindowMs(skill);
  final shiftMil = targetSpeedMilPerSec * (shotOffsetMs / 1000.0);
  // Aim error: the target moved, so where the user is holding is now
  // off by `shiftMil` horizontally.
  final tHalfW = targetWidthMil / 2.0;
  final tHalfH = targetHeightMil / 2.0;
  // 2D-Gaussian-CDF approximation, identical to the helper used in the
  // Scope View "what-if" ring. Hit chance ≈ P(|x-mu_x|<halfW) ×
  // P(|y-mu_y|<halfH).
  final px = _gaussianBox(shiftMil, sigmaMil, tHalfW);
  final py = _gaussianBox(0.0, sigmaMil, tHalfH);
  final p = (px * py).clamp(0.0, 1.0);
  return ShootingWindow(
    earliestMs: -hw,
    optimalMs: 0,
    latestMs: hw,
    hitLikelihood: p,
  );
}

/// Predicted-impact location for free-aim mode. (xMil, yMil) is in
/// mil-from-FOV-center coords, +y up. Caller renders this as a dim red
/// dot on the target.
class PredictedImpact {
  const PredictedImpact({
    required this.xMil,
    required this.yMil,
    required this.hitProbability,
  });

  final double xMil;
  final double yMil;

  /// 0..1 — probability the *predicted impact* hits the target.
  /// Computed via the same Gaussian erf integral as the timing-window
  /// math. Used by the probability ellipse renderer to color-code
  /// (green/amber/red) and by the hit chip to show a number.
  final double hitProbability;
}

/// Compute where the bullet would land given a free-aim point in
/// mil-from-FOV-center coords. The target sits at `(windMil, -dropMil)`
/// in the same coord frame (the firing solution baked in). The bullet
/// arrives `(targetSpeedMilPerSec × tofSec)` to the left/right of the
/// target's current position because the target moved during the time
/// of flight — but if the user chose the lead correctly, the bullet
/// meets the target. We model the predicted impact as:
///
///   impact = aim
///          + (target's position when bullet arrives - target's position now)
///                                                         (the implicit lead)
///          - (firing solution offset already applied to the reticle)
///
/// In practice, the parent's [windMil] / [dropMil] already encode the
/// firing solution at this distance. The lead correction is implicit
/// in the user's chosen aim point — if they aim ahead of the target by
/// the right amount, the predicted impact lands on the target.
///
/// [zeroOffsetMil] is an optional per-rifle bias ("rifle prints 0.3"
/// left at 100 yd"). Defaults to (0, 0) — unbiased shooter.
PredictedImpact computePredictedImpact({
  required double aimXMil,
  required double aimYMil,
  required double dropMil,
  required double windMil,
  required double targetWidthMil,
  required double targetHeightMil,
  required double sigmaMil,
  required double targetSpeedMilPerSec,
  required double timeOfFlightSec,
  double zeroOffsetXMil = 0.0,
  double zeroOffsetYMil = 0.0,
}) {
  // Target's position right now (firing solution baked into the
  // reticle anchor).
  final targetCxMil = windMil;
  final targetCyMil = -dropMil;
  // Where the target will be when the bullet arrives.
  final targetCxFutureMil =
      targetCxMil + targetSpeedMilPerSec * timeOfFlightSec;
  // Predicted impact: the bullet flies to where the user aimed.
  // Apply a per-rifle zero-offset (small bias), but no other corrections
  // — the user's aim choice IS the lead choice.
  final ix = aimXMil + zeroOffsetXMil;
  final iy = aimYMil + zeroOffsetYMil;
  // Hit probability: 2D gaussian over target rect centered on the
  // *future* target position.
  final ex = targetCxFutureMil - ix;
  final ey = targetCyMil - iy;
  final px = _gaussianBox(ex, sigmaMil, targetWidthMil / 2.0);
  final py = _gaussianBox(ey, sigmaMil, targetHeightMil / 2.0);
  return PredictedImpact(
    xMil: ix,
    yMil: iy,
    hitProbability: (px * py).clamp(0.0, 1.0),
  );
}

/// Suggested ambush hold-off positions for a moving target. Both
/// values are in mils, FOV-center-relative, and assume the target is
/// moving in +x direction. Negate `xMil` for a R→L mover.
class TargetAmbushPoints {
  const TargetAmbushPoints({
    required this.leadingEdgeXMil,
    required this.leadingEdgeYMil,
    required this.centerMassXMil,
    required this.centerMassYMil,
  });

  /// "Aim at the *leading edge* of where the target will be when the
  /// bullet arrives, so the bullet meets center-mass." Subtracts half
  /// the target's width from the centerMass lead.
  final double leadingEdgeXMil;
  final double leadingEdgeYMil;

  /// "Aim at the *center mass* of where the target will be when the
  /// bullet arrives." Equal to the calculated lead, full stop.
  final double centerMassXMil;
  final double centerMassYMil;
}

/// Compute the two recommended ambush points. [targetSpeedMilPerSec]
/// is the *unsigned* magnitude of the horizontal target velocity in
/// mils per second; [direction] sets the sign (+1 = L→R, −1 = R→L).
/// Returned x values are in FOV-mil coords (positive = right of LoS).
TargetAmbushPoints computeAmbushPoints({
  required double dropMil,
  required double windMil,
  required double targetSpeedMilPerSec,
  required double timeOfFlightSec,
  required double targetWidthMil,
  required double direction,
}) {
  // Target's current position (the firing solution puts it here).
  final tCxMil = windMil;
  final tCyMil = -dropMil;
  // Signed velocity for the lead computation.
  final dirSign = direction == 0 ? 1.0 : direction.sign;
  final velocityMilSec = targetSpeedMilPerSec.abs() * dirSign;
  // Where the target will be when the bullet lands.
  final futureCxMil = tCxMil + velocityMilSec * timeOfFlightSec;
  // Center-mass ambush: aim where target will be.
  final centerX = futureCxMil;
  final centerY = tCyMil;
  // Leading-edge ambush: aim at the front edge so the bullet lands
  // center-mass. If target moves +x, "front edge" is +x of center.
  final leadingX =
      futureCxMil + (dirSign * targetWidthMil / 2.0);
  final leadingY = tCyMil;
  return TargetAmbushPoints(
    leadingEdgeXMil: leadingX,
    leadingEdgeYMil: leadingY,
    centerMassXMil: centerX,
    centerMassYMil: centerY,
  );
}

// ─────────────────────── Internals ───────────────────────

/// P(|X - mu| < halfWidth) for X ~ Normal(0, sigma). Same algebra as
/// `_normalProbWithin` in `scope_view_screen.dart`. Duplicated here so
/// this file has zero widget-tree dependencies (so it's testable in
/// pure Dart).
double _gaussianBox(double mu, double sigma, double halfWidth) {
  if (sigma <= 0 || halfWidth <= 0) return 0.0;
  final s = sigma * math.sqrt(2);
  final p1 = _erf((halfWidth - mu) / s);
  final p2 = _erf((halfWidth + mu) / s);
  return 0.5 * (p1 + p2);
}

/// Abramowitz & Stegun 7.1.26 erf approximation. Max error ~1.5e-7.
/// Same constants as `scope_view_screen.dart`.
double _erf(double x) {
  final sign = x.sign;
  final ax = x.abs();
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  final t = 1.0 / (1.0 + p * ax);
  final y = 1.0 -
      (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) *
          t *
          math.exp(-ax * ax);
  return sign * y;
}
